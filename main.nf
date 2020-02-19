#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/predictorthologs
========================================================================================
 nf-core/predictorthologs Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/predictorthologs
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/predictorthologs --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads [file]                Path to input data (must be surrounded with quotes)
      -profile [str]                Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, test, awsbatch and more

    Options:
      --genome [str]                  Name of iGenomes reference
      --singleEnd [bool]             Specifies that the input is single-end reads

    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --fasta [file]                  Path to fasta reference

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the channel below in a process, define the following:
//   input:
//   file fasta from ch_fasta
//
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if (params.fasta) { ch_fasta = file(params.fasta, checkIfExists: true) }

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file(params.multiqc_config, checkIfExists: true)
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

/*
 * Create a channel for input read files
 */
if (params.readPaths) {
    if (params.singleEnd) {
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { ch_read_files_fastqc; ch_read_files_trimming; ch_read_files_extract_coding }
    } else {
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true), file(row[1][1], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { ch_read_files_fastqc; ch_read_files_trimming; ch_read_files_extract_coding }
    }
} else {
    Channel
        .fromFilePairs(params.reads, size: params.singleEnd ? 1 : 2)
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --singleEnd on the command line." }
        .into { ch_read_files_fastqc; ch_read_files_trimming; ch_read_files_extract_coding }
}

if (params.extract_coding_peptide_fasta) {
Channel.fromPath(params.extract_coding_peptide_fasta, checkIfExists: true)
     .ifEmpty { exit 1, "Peptide fasta file not found: ${params.extract_coding_peptide_fasta}" }
     .set{ ch_extract_coding_peptide_fasta }
}

if (params.diamond_protein_fasta) {
Channel.fromPath(params.diamond_protein_fasta, checkIfExists: true)
     .ifEmpty { exit 1, "Diamond protein fasta file not found: ${params.diamond_protein_fasta}" }
     .set{ ch_diamond_protein_fasta }
}
if (params.diamond_taxonmap_gz) {
Channel.fromPath(params.diamond_taxonmap_gz, checkIfExists: true)
     .ifEmpty { exit 1, "Diamond Taxon map file not found: ${params.diamond_taxonmap_gz}" }
     .set{ ch_diamond_taxonmap_gz }
}
if (params.diamond_taxdmp_zip) {
Channel.fromPath(params.diamond_taxdmp_zip, checkIfExists: true)
     .ifEmpty { exit 1, "Diamond taxon dump file not found: ${params.diamond_taxdmp_zip}" }
     .set{ ch_diamond_taxdmp_zip }
}



peptide_ksize = params.extract_coding_peptide_ksize
peptide_molecule = params.extract_coding_peptide_molecule
jaccard_threshold = params.extract_coding_jaccard_threshold
diamond_refseq_release = params.diamond_refseq_release

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary['Data Type']        = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-predictorthologs-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/predictorthologs Workflow Summary'
    section_href: 'https://github.com/nf-core/predictorthologs'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}


/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: { filename ->
                      filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                }

    input:
    set val(name), file(reads) from ch_read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into ch_fastqc_results

    script:
    """
    fastqc --quiet --threads $task.cpus $reads
    """
}


/*
 * STEP 2 - fastp for read trimming + merging
 */
process fastp {
    label 'low_memory'
    tag "$name"
    publishDir "${params.outdir}/fastp", mode: 'copy'

    input:
    set val(name), file(reads) from ch_read_files_trimming

    output:
    set val(name), file("*trimmed.fastq.gz") into ch_reads_trimmed
    file "*fastp.json" into fastp_results
    file "*fastp.html" into fastp_html

    script:
    if (params.singleEnd) {
        """
        fastp \\
            --in1 ${reads} \\
            --out1 ${name}_R1_trimmed.fastq.gz \\
            --json ${name}_fastp.json \\
            --html ${name}_fastp.html
        """
    } else {
        """
        fastp \\
            --in1 ${reads[0]} \\
            --in2 ${reads[1]} \\
            --out1 ${name}_R1_trimmed.fastq.gz \\
            --out2 ${name}_R2_trimmed.fastq.gz \\
            --json ${name}_fastp.json \\
            --html ${name}_fastp.html
        """
    }
}


process khtools_peptide_bloom_filter {
  tag "${peptides}__${bloom_id}"
  label "low_memory"

  publishDir "${params.outdir}/khtools/bloom_filter/", mode: 'copy'

  input:
  file(peptides) from ch_extract_coding_peptide_fasta
  each molecule from peptide_molecule

  output:
  set val(bloom_id), val(molecule), file("${peptides.simpleName}__${bloom_id}.bloomfilter") into ch_khtools_bloom_filters

  script:
  bloom_id = "molecule-${molecule}"
  """
  khtools bloom-filter \\
    --tablesize 1e7 \\
    --molecule ${molecule} \\
    --save-as ${peptides.simpleName}__${bloom_id}.bloomfilter \\
    ${peptides}
  """
}

// From Paolo - how to do extract_coding on ALL combinations of bloom filters
 ch_khtools_bloom_filters
  .groupTuple(by: [0, 3])
  .combine(ch_reads_trimmed)
  .set{ ch_khtools_bloom_filters_grouptuple }


process extract_coding {
  tag "${sample_id}"
  label "low_memory"
  publishDir "${params.outdir}/extract_coding/", mode: 'copy'

  input:
  tuple \
    val(bloom_id), val(alphabet), file(bloom_filter), \
    val(sample_id), file(reads) \
      from ch_khtools_bloom_filters_grouptuple

  output:
  // TODO also extract nucleotide sequence of coding reads and do sourmash compute using only DNA on that?
  set val(sample_id), file("${sample_id}__coding_reads_peptides.fasta") into ch_coding_peptides
  set val(sample_id), file("${sample_id}__coding_reads_nucleotides.fasta") into ch_coding_nucleotides
  set val(sample_id), file("${sample_id}__coding_scores.csv") into ch_coding_scores_csv
  set val(sample_id), file("${sample_id}__coding_summary.json") into ch_coding_scores_json

  script:
  """
  khtools extract-coding \\
    --molecule ${alphabet[0]} \\
    --coding-nucleotide-fasta ${sample_id}__coding_reads_nucleotides.fasta \\
    --csv ${sample_id}__coding_scores.csv \\
    --json-summary ${sample_id}__coding_summary.json \\
    --peptides-are-bloom-filter \\
    ${bloom_filter} \\
    ${reads} > ${sample_id}__coding_reads_peptides.fasta
  """
}
// Remove empty files
// it[0] = sample id
// it[1] = sequence fasta file
ch_coding_nucleotides_nonempty = ch_coding_nucleotides.filter{ it[1].size() > 0 }
ch_coding_peptides_nonempty = ch_coding_peptides.filter{ it[1].size() > 0 }


if (!params.diamond_protein_fasta){
  // No protein fasta provided for searching for orthologs, need to
  // download refseq
  process download_refseq {
    tag "${sample_id}"
    label "low_memory"

    publishDir "${params.outdir}/ncbi_refseq/", mode: 'copy'

    input:
    val refseq_release from diamond_refseq_release

    output:
    set file("${refseq_release}__${task.start}.fa.gz") into ch_diamond_protein_fasta

    script:
    """
    rsync \
          --prune-empty-dirs \
          --archive \
          --verbose \
          -recursive \
          --include '*protein.faa.gz' \
          --exclude '/*' \
          rsync://ftp.ncbi.nlm.nih.gov/refseq/release/${refseq_release}/ .
    zcat *.protein.faa.gz | gzip -c - > ${refseq_release}__${task.start}.fa.gz
    """
  }
}


process diamond_prepare_taxa {
  tag "${taxondmp_zip.baseName}"
  label "low_memory"

  publishDir "${params.outdir}/ncbi_refseq/", mode: 'copy'

  input:
  file(taxondmp_zip) from ch_diamond_taxdmp_zip

  output:
  file("nodes.dmp") into ch_diamond_taxonnodes
  file("names.dmp") into ch_diamond_taxonnames

  script:
  """
  unzip ${taxondmp_zip}
  """
}


//

process diamond_makedb {
  tag "${reference_proteome.baseName}"
  label "low_memory"

  publishDir "${params.outdir}/diamond/makedb/", mode: 'copy'

  input:
  file(reference_proteome) from ch_diamond_protein_fasta
  file(taxonnodes) from ch_diamond_taxonnodes
  file(taxonnames) from ch_diamond_taxonnames
  file(taxonmap_gz) from ch_diamond_taxonmap_gz

  output:
  file("*_db.dmnd") into ch_diamond_db

  script:
  """
  diamond makedb \\
      -d ${reference_proteome.baseName}_db \\
      --taxonmap ${taxonmap_gz} \\
      --taxonnodes ${taxonnodes} \\
      --taxonnames ${taxonnames} \\
      --in ${reference_proteome}
  """
}

process diamond_blastp {
  tag "${sample_id}"
  label "low_memory"

  publishDir "${params.outdir}/diamond/blastp/", mode: 'copy'

  input:
  set sample_id, file(coding_peptides) from ch_coding_peptides_nonempty
  file(diamond_db) from ch_diamond_db

  output:
  file("${coding_peptides.baseName}__diamond__${diamond_db.baseName}.tsv") into ch_diamond_blastp_output

  script:
  """
  diamond blastp \\
      --threads ${task.cpus} \\
      --max-target-seqs 3 \\
      --db ${diamond_db} \\
      --evalue 0.00000000001  \\
      --query ${coding_peptides} \\
      > ${coding_peptides.baseName}__diamond__${diamond_db.baseName}.tsv
  """
}



/*
 * STEP 2 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    // file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/predictorthologs] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/predictorthologs] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/predictorthologs] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/predictorthologs] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/predictorthologs] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/predictorthologs] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/predictorthologs]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/predictorthologs]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/predictorthologs v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
