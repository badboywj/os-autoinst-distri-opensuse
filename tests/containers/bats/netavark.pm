# SUSE's openQA tests
#
# Copyright 2024,2025 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Package: netavark
# Summary: Upstream netavark integration tests
# Maintainer: QE-C team <qa-c@suse.de>

use Mojo::Base 'containers::basetest';
use testapi;
use serial_terminal qw(select_serial_terminal);
use utils qw(script_retry);
use containers::common;
use containers::bats;
use version_utils qw(is_sle is_tumbleweed);

my $test_dir = "/var/tmp/netavark-tests";
my $netavark;

sub run_tests {
    my %env = (
        NETAVARK => $netavark,
    );

    my $log_file = "netavark.tap";

    return bats_tests($log_file, \%env, "");
}

sub run {
    my ($self) = @_;
    select_serial_terminal;

    my @pkgs = qw(aardvark-dns cargo firewalld iproute2 jq make protobuf-devel netavark);
    if (is_tumbleweed || is_sle('>=16.0')) {
        push @pkgs, qw(dbus-1-daemon);
    } elsif (is_sle) {
        push @pkgs, qw(dbus-1);
    }

    $self->bats_setup(@pkgs);

    install_ncat;

    $netavark = script_output "rpm -ql netavark | grep podman/netavark";
    record_info("netavark version", script_output("$netavark --version"));
    record_info("netavark package version", script_output("rpm -q netavark"));

    # Download netavark sources
    my $netavark_version = script_output "$netavark --version | awk '{ print \$2 }'";
    my $url = get_var("BATS_URL", "https://github.com/containers/netavark/archive/refs/tags/v$netavark_version.tar.gz");
    assert_script_run "mkdir -p $test_dir";
    assert_script_run "cd $test_dir";
    script_retry("curl -sL $url | tar -zxf - --strip-components 1", retry => 5, delay => 60, timeout => 300);

    my $firewalld_backend = script_output "awk -F= '\$1 == \"FirewallBackend\" { print \$2 }' < /etc/firewalld/firewalld.conf";
    record_info("Firewalld backend", $firewalld_backend);

    # Compile helpers & patch tests
    assert_script_run "make examples", timeout => 600;
    assert_script_run "rm -f test/100-bridge-iptables.bats" if ($firewalld_backend ne "iptables");

    my $errors = run_tests;
    die "netavark tests failed" if ($errors);
}

sub post_fail_hook {
    bats_post_hook $test_dir;
}

sub post_run_hook {
    bats_post_hook $test_dir;
}

1;
