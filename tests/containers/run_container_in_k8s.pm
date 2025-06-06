# SUSE's openQA tests
#
# Copyright 2021-2023 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Push a container image to the public cloud container registry
#
# Maintainer: QE-C team <qa-c@suse.de>

use strict;
use warnings;
use Mojo::Base 'publiccloud::k8sbasetest';
use testapi;
use containers::k8s qw(apply_manifest wait_for_k8s_job_complete find_pods validate_pod_log);
use version_utils qw(is_sle);

sub run {
    my ($self, $run_args) = @_;
    if ($run_args->{provider}) {
        my $provider = shift(@{$run_args->{provider}});
        $self->SUPER::init(provider => $provider);
    }
    else {
        $self->SUPER::init();
    }

    my $cmd = '"cat", "/etc/os-release"';

    $self->{image_tag} = $run_args->{image_tag};
    my $image = $self->{provider}->get_container_image_full_name($run_args->{image_tag});
    my $job_name = $run_args->{image_tag} =~ s/_/-/gr;
    $self->{job_name} = $job_name;

    my $manifest = <<EOT;
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
spec:
  template:
    spec:
      containers:
      - name: main
        image: $image
        command: [ $cmd ]
        resources:
          limits:
            cpu: "0.5"
            memory: 256Mi
          requests:
            cpu: "0.1"  
            memory: 128Mi
      restartPolicy: Never
  backoffLimit: 4
  ttlSecondsAfterFinished: 30
  activeDeadlineSeconds: 1700
EOT

    record_info('Manifest', "Applying manifest:\n$manifest");
    apply_manifest($manifest);
    wait_for_k8s_job_complete($job_name);
    my $pod = find_pods("job-name=$job_name");
    validate_pod_log($pod, is_sle('16.0+') ? "SUSE Linux" : "SUSE Linux Enterprise Server");
    record_info('cmd', "Command `$cmd` successfully executed in the image.");
}

sub cleanup {
    my ($self) = @_;
    record_info('Cleanup', 'Deleting kubectl job and image.');
    # wait for confirmation that resource has been removed
    assert_script_run("kubectl delete job --force $self->{job_name}", timeout => 120);
    $self->{provider}->delete_container_image($self->{image_tag});
    script_run("kubectl describe job $self->{job_name}");
    # might be useful for future debug, sometimes the jobs keep hanging
    record_info('jobs', script_output('kubectl get jobs', timeout => 120, proceed_on_failure => 1));
}

sub post_fail_hook {
    my ($self) = @_;
    $self->cleanup();
}

sub post_run_hook {
    my ($self) = @_;
    $self->cleanup();
}

sub test_flags {
    return {fatal => 0};
}

1;
