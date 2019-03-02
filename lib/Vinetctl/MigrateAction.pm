package Vinetctl::MigrateAction;

# Copyright (c) 2019 Dale Lindskog <dale.lindskog@gmail.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
# IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
# OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use feature qw( say );
use Net::Ping;
use Net::SFTP::Foreign;
use Term::ReadKey;
use Hash::Util qw( lock_value unlock_value );
use File::stat qw( stat );

use Vinetctl::Globals qw( 
    %args 
    %rc 
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
    Warn
);

use Vinetctl::RunningAction qw( 
    get_running_topologies
);

use Vinetctl::Topology qw(
    init_topology
);

# need this to chk if migrate save is finished
use Vinetctl::StatusAction qw(
    get_vm_status
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    migrate_action
);

# migrate_action(): run migrate_topology() for $args{f},
# or for all running topologies of $args{f} is unset
#########################################################
sub migrate_action {
    report_calling_stack(@_) if $args{d};

    my @params = @{ $globals{action_params} };
    Die "'@params': vm list acceptable only with -f\n"
        if @params and not $args{f};

    # are all local files in order?
    ################################

    my @topologies; 
    if ( $args{f} ) {
        push( @topologies, $args{f} )
    }
    else {
        # if args{v} set then get_running_topologies() gives too much info:
        local $args{v} = undef;
        @topologies = @{ get_running_topologies() };
    }
    print "migrating: @topologies\n";
    
    foreach my $topology ( @topologies ) {

        # initialize the topology
        ##########################

        unlock_value( %globals, 'topology_name' );
        $globals{topology_name} = $topology;
        init_topology or Die "$topology: init_topology failed\n";
        lock_value( %globals, 'topology_name' );

        # does our local directory exist; if so, go there
        ##################################################
        my $localdir = "$rc{migrate_out_dir}/$globals{topology_name}";
        -d $localdir or Die "$localdir: no such directory\n"; 
        chdir $localdir or Die "couldn't chdir to $localdir: $!\n";

        # construct a list of migrate files and make sure they exist
        #############################################################

        my @vms = grep { defined } @{ $globals{vm_list} };
        my @migrate_files = map { "$_->{name}.gz" } @vms;
        foreach my $file ( @migrate_files ) { 
            -e $file 
                or Die "$localdir/$file doesn't exist.  Did you save?\n";
            -r _ 
                or Die "$localdir/$file is not readable\n";
            my $secs_old = time() - stat($file)->mtime;
            if ( $secs_old > 300 and not $args{F} ) { 
                Die "$rc{migrate_out_dir}/$globals{topology_name}/$file: ",
                    "greater than 5 minutes old: ",
                    "-m save first (or -F to force)\n";
            }
        }

    }

    # is the migrate backup host reachable?
    #######################################

    print "checking $rc{migrate_host}:$rc{backup_port}...  " 
        if $args{v};
    my $p = Net::Ping->new();
    $p->port_number( $rc{backup_port} );
    $p->ping( $rc{migrate_host} )
        or Die "backup host $rc{migrate_host} unreachable.\n";
    print "up\n" if $args{v};

    # get the password for remote host
    ###################################
    # TODO: support both pword and keypair (transparently)
    ########################################################

    print "password:";
    ReadMode('noecho');
    chomp( my $password = ReadLine(0) );
    ReadMode('normal');
    print "\n";

    # connect to ssh server on backup host
    #######################################

    print "connecting to $rc{migrate_host}:$rc{backup_port}...  " 
        if $args{v};
    my $sftp = Net::SFTP::Foreign->new(
        host=> $rc{migrate_host}, 
        port => $rc{backup_port}, 
        password => $password,
    );
    $sftp->die_on_error("Unable to establish SFTP connection");
    print "ok\n" 
        if $args{v};

    return( report_retval(migrate_topology($sftp)) ) 
        if $args{f};

    foreach my $topology ( @topologies ) {
        unlock_value( %globals, 'topology_name' );
        $globals{topology_name} = $topology;
        init_topology or Die "$topology: init_topology failed\n";
        lock_value( %globals, 'topology_name' );
        my $retval = migrate_topology($sftp); 
        print "$globals{topology_name}", $retval ? "(ok)\n" : "(fail)\n";
    }
}

# migrate_topology(): sftp migrate files associated with topology
##################################################################
sub migrate_topology {
    report_calling_stack(@_) if $args{d};

    my $sftp = shift;

    # does our local directory exist; if so, go there
    ##################################################

    my $localdir = "$rc{migrate_out_dir}/$globals{topology_name}";
    -d $localdir or Die "$localdir: no such directory\n"; 
    chdir $localdir or Die "couldn't chdir to $localdir: $!\n";
    print "chdir to local: $localdir successful\n" if $args{v};

    # construct a list of migrate files and make sure they exist
    #############################################################

    my @vms = grep { defined } @{ $globals{vm_list} };
    my @migrate_files = map { "$_->{name}.gz" } @vms;
    foreach my $file ( @migrate_files ) {
        -r $file or Die "$localdir/$file is not readable\n";
        my $secs_old = time() - stat($file)->mtime;
        if ( $secs_old > 300 and not $args{F} ) { 
            Die "$file: greater than 5 minutes old: ",
                "-m save first (or -F to force)\n";
        }
    }

    # make sure '-m save' is finished
    ##################################
    foreach my $vm ( @vms ) {
        my $status = get_vm_status($vm);
        Die "$vm->{name} is not in the paused_postmigrate state: ",
            "see '-v status' action\n"
            unless $status eq "paused_postmigrate";
    }

    # transfer the migrate files
    #############################

    my $remotedir = "$rc{migrate_in_dir}/$globals{topology_name}";
    my $response;
    if ( $sftp->setcwd($remotedir) ) { 
        print "cwd to $remotedir\n" if $args{v};
    }
    else {
        Warn "$remotedir: " . $sftp->error . "\n"; 
        my $resp;
        if ( $args{F} ) { 
            $resp = 'yes'; 
            say "Creating $remotedir...";
        }
        else {
            print "Create? [y/n] "; 
            chomp( $response = <STDIN> ); 
        }
        if ( $response eq 'y' or $response eq 'yes' ) {
            $sftp->mkpath( $remotedir ) 
                or Die "couldn't create $remotedir: "
                      . $sftp->error . "\n";
            $sftp->setcwd($remotedir)
                or Die "couldn't chdir to remote $remotedir: "
                      . $sftp->error . "\n";
        }
        else { return( report_retval(0) ) }
    }

    if ( $sftp->mput(\@migrate_files) ) {
        print "mput @migrate_files to $remotedir\n" if $args{v};
    }
    else {
        Warn "unable to mput: " . $sftp->error;
        return( report_retval(0) );
    }

    return( report_retval(1) );
}

1;
