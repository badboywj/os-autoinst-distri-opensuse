# SUSE's openQA tests
#
# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: FSFAP
#
# Summary: Functions to use qe-sap-deployment project
# Maintainer: QE-SAP <qe-sap@suse.de>

## no critic (RequireFilenameMatchesPackage);

=encoding utf8

=head1 NAME

    qe-sap-deployment test lib

=head1 COPYRIGHT

    Copyright 2022 SUSE LLC
    SPDX-License-Identifier: FSFAP

=head1 AUTHORS

    QE SAP <qe-sap@suse.de>

=cut

package qesapdeployment;

use strict;
use warnings;
use utils 'file_content_replace';
use testapi;
use Exporter 'import';
use Data::Dumper;


my @log_files = ();

# Terraform requirement
#  terraform/azure/infrastructure.tf  "azurerm_storage_account" "mytfstorageacc"
# stdiag<PREFID><JOB_ID> can only consist of lowercase letters and numbers,
# and must be between 3 and 24 characters long
use constant QESAPDEPLOY_PREFIX => 'qesapdep';

our @EXPORT = qw(
  qesap_create_folder_tree
  qesap_pip_install
  qesap_upload_logs
  qesap_get_deployment_code
  qesap_prepare_env
  qesap_execute
  qesap_yaml_replace
);

=head1 DESCRIPTION

    Package with common methods and default or constant  values for qe-sap-deployment
=head2 Methods


=head3 qesap_get_file_paths

    Returns a hash containing file paths for config files
=cut

sub qesap_get_file_paths {
    my %paths;
    $paths{qesap_conf_filename} = get_required_var('QESAP_CONFIG_FILE');
    $paths{deployment_dir} = get_var('DEPLOYMENT_DIR', '/root/qe-sap-deployment');
    $paths{terraform_dir} = get_var('PUBLIC_CLOUD_TERRAFORM_DIR', $paths{deployment_dir} . '/terraform/');
    $paths{qesap_conf_trgt} = $paths{deployment_dir} . "/scripts/qesap/" . $paths{qesap_conf_filename};
    return (%paths);
}

=head3 qesap_create_folder_tree

    Create all needed folders
=cut

sub qesap_create_folder_tree {
    my %paths = qesap_get_file_paths();
    assert_script_run("mkdir -p $paths{deployment_dir}", quiet => 1);
}

=head3 qesap_pip_install

  Install all Python requirements of the qe-sap-deployment

=cut

sub qesap_pip_install {
    enter_cmd 'pip config --site set global.progress_bar off';
    my $pip_ints_cmd = 'pip install --no-color --no-cache-dir ';
    my $pip_install_log = '/tmp/pip_install.txt';
    my %paths = qesap_get_file_paths();

    # Hack to fix an installation conflict. Someone install PyYAML 6.0 and awscli needs an older one
    push(@log_files, $pip_install_log);
    record_info("QESAP repo", "Installing pip requirements");
    assert_script_run(join(" ", $pip_ints_cmd, 'awscli==1.19.48 | tee', $pip_install_log), 180);
    assert_script_run(join(" ", $pip_ints_cmd, '-r', $paths{deployment_dir} . '/requirements.txt | tee -a', $pip_install_log), 180);
}

=head3 qesap_upload_logs

    qesap_upload_logs([failok=1])

    Collect and upload logs present in @log_files.
    failok - continue even in case upload fails

=cut

sub qesap_upload_logs {
    my (%args) = @_;
    my $failok = $args{failok};
    record_info("Uploading logfiles", join("\n", @log_files));
    for my $file (@log_files) {
        upload_logs($file, failok => $failok);
    }
    # Remove already uploaded files from arrays
    @log_files = ();
}

=head3 qesap_get_deployment_code

    Get the qe-sap-deployment code
=cut

sub qesap_get_deployment_code {
    my $git_repo = get_var(QESAPDEPLOY_GITHUB_REPO => 'github.com/SUSE/qe-sap-deployment');
    my $qesap_git_clone_log = '/tmp/git_clone.txt';
    my %paths = qesap_get_file_paths();

    record_info("QESAP repo", "Preparing qe-sap-deployment repository");
    qesap_create_folder_tree();
    enter_cmd "cd " . $paths{deployment_dir};

    # Script from a release
    if (get_var('QESAPDEPLOY_VER')) {
        my $ver_artifact = 'v' . get_var('QESAPDEPLOY_VER') . '.tar.gz';

        my $curl_cmd = "curl -v -L https://$git_repo/archive/refs/tags/$ver_artifact -o$ver_artifact";
        assert_script_run("set -o pipefail ; $curl_cmd | tee " . $qesap_git_clone_log, quiet => 1);

        my $tar_cmd = "tar xvf $ver_artifact --strip-components=1";
        assert_script_run($tar_cmd);
        enter_cmd 'ls -lai';
    }
    else {
        # Get the code for the qe-sap-deployment by cloning its repository
        assert_script_run('git config --global http.sslVerify false', quiet => 1) if get_var('QESAPDEPLOY_GIT_NO_VERIFY');
        my $git_branch = get_var('QESAPDEPLOY_GITHUB_BRANCH', 'main');

        my $git_clone_cmd = 'git clone --depth 1 --branch ' . $git_branch . ' https://' . $git_repo . ' ' . $paths{deployment_dir};
        push(@log_files, $qesap_git_clone_log);
        assert_script_run("set -o pipefail ; $git_clone_cmd | tee " . $qesap_git_clone_log, quiet => 1);
    }
    # Add symlinks for different provider directory naming between OpenQA and qesap-deployment
    assert_script_run("ln -s " . $paths{terraform_dir} . "/aws " . $paths{terraform_dir} . "/ec2");
    assert_script_run("ln -s " . $paths{terraform_dir} . "/gcp " . $paths{terraform_dir} . "/gce");
}

=head3 qesap_yaml_replace

    Replaces yaml config file variables with parameters defined by OpenQA testode, yaml template or yaml schedule.
    Openqa variables need to be added as a hash with key/value pair inside %run_args{openqa_variables}.
    Example:
        my %variables;
        $variables{HANA_SAR} = get_required_var("HANA_SAR");
        $variables{HANA_CLIENT_SAR} = get_required_var("HANA_CLIENT_SAR");
        qesap_yaml_replace(openqa_variables=>\%variables);
=cut

sub qesap_yaml_replace {
    my (%args) = @_;
    my $variables = $args{openqa_variables};
    my %replaced_variables = ();
    my %paths = qesap_get_file_paths();
    push(@log_files, $paths{qesap_conf_trgt});

    for my $variable (keys %{$variables}) {
        $replaced_variables{"%" . $variable . "%"} = $variables->{$variable};
    }
    file_content_replace($paths{qesap_conf_trgt}, %replaced_variables);
    qesap_upload_logs();
}


=head3 qesap_execute

    qesap_execute(cmd => $qesap_script_cmd [, verbose => 1] );

    Execute qesap glue script commands. Check project documentation for available options:
    https://github.com/SUSE/qe-sap-deployment
=cut

sub qesap_execute {
    my (%args) = @_;
    die 'QESAP command to execute undefined' unless $args{cmd};

    my $verbose = $args{verbose} ? "--verbose" : "";
    my %paths = qesap_get_file_paths();
    my $qesap_cmd = join(" ", $paths{deployment_dir} . "/scripts/qesap/qesap.py", $verbose, "-c", $paths{qesap_conf_trgt}, "-b", $paths{deployment_dir});
    my $exec_log = "/tmp/qesap_exec_" . $args{cmd} . ".log.txt";
    push(@log_files, $exec_log);

    record_info('QESAP exec', 'Executing: \n' . $qesap_cmd . " " . $args{cmd});

    if ($args{timeout}) {
        assert_script_run(join(" ", $qesap_cmd, $args{cmd}, "2>&1 | tee -a", $exec_log), timeout => $args{timeout});
    }
    else {
        assert_script_run(join(" ", $qesap_cmd, $args{cmd}, "2>&1 | tee -a", $exec_log));
    }

    qesap_upload_logs();
}


=head3 qesap_prepare_env

    qesap_prepare_env(variables=>{dict with variables});

    Prepare terraform environment.
    - creates file structures
    - pulls git repository
    - external config files
    - installs pip requirements and OS packages
    - generates config files with qesap script

    For variables example see 'qesap_yaml_replace'
=cut

sub qesap_prepare_env {
    my (%args) = @_;
    my $variables = $args{openqa_variables};
    my $provider = lc get_required_var('PUBLIC_CLOUD_PROVIDER');
    my %paths = qesap_get_file_paths();
    my $tfvars_template = get_var('QESAP_TFVARS_TEMPLATE');
    my $qesap_conf_src = "sles4sap/qe_sap_deployment/" . $paths{qesap_conf_filename};
    my $curl = "curl -v -L ";

    qesap_get_deployment_code();
    qesap_pip_install();

    # Copy tfvars template file if defined in parameters
    if (get_var('QESAP_TFVARS_TEMPLATE')) {
        record_info("QESAP tfvars template", "Preparing terraform template: \n" . $tfvars_template);
        assert_script_run('cd ' . $paths{terraform_dir} . $provider, quiet => 1);
        assert_script_run('cp ' . $tfvars_template . ' terraform.tfvars.template');
    }

    record_info("QESAP yaml", "Preparing yaml config file");
    assert_script_run($curl . data_url($qesap_conf_src) . ' -o ' . $paths{qesap_conf_trgt});
    qesap_yaml_replace(openqa_variables => $variables);

    record_info("QESAP conf", "Generating tfvars file");
    qesap_execute(cmd => 'configure', verbose => 1);
    push(@log_files, $paths{terraform_dir} . $provider . "/terraform.tfvars");
    qesap_upload_logs();
}

1;