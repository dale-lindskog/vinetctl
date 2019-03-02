package Vinetctl::Main;

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
use constant { TRUE => 1, FALSE => 0 };
use File::Path qw( make_path );
use Hash::Util qw( lock_hash unlock_hash );

use UI::Dialog;  # for dialog menus

use Vinetctl::Globals qw( 
    %globals 
    %rc 
    %args 
);

use Vinetctl::Debug qw( 
    report_calling_stack 
    report_retval 
    Die 
    Warn 
);

use Vinetctl::Dialog qw( 
    dialog 
    dialog_choose_vms 
    dialog_set_from_list
);

use Vinetctl::Topology qw( 
    init_topology 
);

use Vinetctl::Init qw(
    chk_external_prog_dependencies 
    get_ipaddr 
    get_topology_owner 
    get_topology_name
    chk_options 
    clean_action_params
    copy_topology_file
    get_action_name 
);

# use() all the action modules
###############################

use Vinetctl::HelpAction         qw( help_action usage );
use Vinetctl::CheckAction        qw( check_action );
use Vinetctl::AllAction          qw( all_action );
use Vinetctl::RunningAction      qw( running_action );
use Vinetctl::ConfigAction       qw( config_action );
use Vinetctl::PortsAction        qw( ports_action );
use Vinetctl::GrantAction        qw( grant_action );
use Vinetctl::SetAction          qw( set_action );
use Vinetctl::UnsetAction        qw( unset_action );
use Vinetctl::ListAction         qw( list_action );
use Vinetctl::ResetAction        qw( reset_action );
use Vinetctl::StatusAction       qw( status_action );
use Vinetctl::DisksAction        qw( disks_action );
use Vinetctl::StartRestoreAction qw( start_restore_action );
use Vinetctl::ShowDiagAction     qw( show_diag_action );
use Vinetctl::DupAction          qw( dup_action );
use Vinetctl::UndupAction        qw( undup_action );
use Vinetctl::ConnectAction      qw( connect_action );
use Vinetctl::DisconnectAction   qw( disconnect_action );
use Vinetctl::DestroyAction      qw( destroy_action );
use Vinetctl::CatAction          qw( cat_action );
use Vinetctl::MonitorAction      qw( monitor_action );
use Vinetctl::RmcableAction      qw( rmcable_action );
use Vinetctl::TopAction          qw( top_action );
use Vinetctl::PsKillAction       qw( ps_kill_action );
use Vinetctl::BackupAction       qw( backup_action );
use Vinetctl::Wires              qw( destroy_dead_wires );
use Vinetctl::MigrateAction      qw( migrate_action );
#use Vinetctl::DesignAction       qw( design_action );
use Vinetctl::BasifyAction       qw( basify_action );
use Vinetctl::EditAction         qw( edit_action );
use Vinetctl::DialogInstall      qw( dialog_install_action ); 
use Vinetctl::DialogStandalone   qw( dialog_standalone_action );
use Vinetctl::StopSaveSuspendResumeAction qw( 
    stop_save_suspend_resume_action 
);

use Exporter qw( import );
our @EXPORT_OK = qw(
    main 
);

# main(): housekeeping, set up topology, loop if using dialog menus
####################################################################

sub main { 
    report_calling_stack(@_) if $args{d};

    # help if -h:
    if ( $args{h} ) {
        print usage();
        exit 0;
    }

    # create some directories
    make_path( $rc{vm_img_dir}, $rc{topology_dir}, $rc{priv_base_img_dir} ); 
    
    # %action2sub: name => subref
    my %action2sub;      # action_name => action_subref
    get_dispatch_table( \%action2sub ); 

    # process external program dependencies
    ########################################

    # disable actions for which external prog depends are missing
    my %disabled_actions = %{ disable_actions() };

    # can we share topologies using ACLs, or must we use groups?
    -e $rc{getfacl} and -e $rc{setfacl} or $rc{grant_type} = 'groups';
    
    # die if we do not have essential external programs
    chk_external_prog_dependencies();   # this sub dies when appropriate

    # dialog flag: set to true with -D switch
    unlock_hash( %globals ); 
    $globals{dialog_loop} = $args{D} ? TRUE : FALSE; 

    # sanity chks on naming of images and topology files
    #####################################################

    # images
    IMG_DIR: foreach my $img_dir ($rc{base_img_dir}, $rc{priv_base_img_dir}) {
        opendir(my $dh, $img_dir) 
            or Warn("cannot open $img_dir: $!\n") and next IMG_DIR;
        while( my $image = readdir $dh ) { 
            # skip '.', '..' and ISOs
            next if $image =~ m/^\./; 
            next if $image =~ m/\.iso$/;
            my @pieces = split( /[-.]/, $image ); 
            my $err = 0;
            $err++ unless @pieces == 3; 
            foreach my $piece (@pieces) { 
                $err++ unless $piece =~ m/^[a-zA-Z0-9_]+$/;
            }
            Die( "$img_dir/$image:", 
                 "not in form NAME-base.EXT,", 
                 "with NAME and EXT being alphanumeric\n" )
                if $err;
        }
        closedir $dh;
    }

    # topology files 
    TOP_DIR: foreach my $top_dir ($rc{topology_dir}, $rc{topology_base_dir}) {
        opendir(my $dh, $top_dir) 
            or Warn("cannot open $top_dir: $!\n") and next TOP_DIR; 
        while( my $top = readdir $dh ) { 
            next if $top =~ m/^\./; 
            Die "$top_dir/$top: ",
                "topology files may use A-Z, a-z, 0-9, - and _ only\n"
                unless $top =~ /^[a-zA-Z0-9_-]+~?$/;
        }
    }

    # main (pseudo) loop: once only unless in dialog loop
    ######################################################

    LOOP: { 

        # jump to dialog here; dialog()'s return value(s) replace
        # cmdline parameters: 

        my( $output, $output_fh );
        if ( $globals{dialog_loop} ) {

            # redirect stdout to variable if using dialog
            # (below we put this output in a dialog box) 
            open( $output_fh, '>', \$output )
                or Die "cannot redirect STDERR: $!\n";
            select $output_fh;
            @_ = dialog(); 

            # if the action is 'install' then we short circuit here,
            # because 'install' is dialog-only
            if ( $_[0] eq 'install' ) {
                redo LOOP if dialog_install_action() eq 'CANCEL'; 
            }
            # same story with 'standalone': 
            if ( $_[0] eq 'standalone' ) {
                redo LOOP if dialog_standalone_action() eq 'CANCEL'; 
            }

            # if the action is 'show', set verbose in menu mode
            $args{v} = 1 if $_[0] eq 'show';

        }
    
        # set values in %globals
        #########################
    
        # first cmdline parameter is the action, but can be abbreviated
        my( $param1, @params ) = @_;

        # expand $param1 to a full action name, if possible:
        $globals{action_name}  = get_action_name( $param1, keys %action2sub ); 
        Warn "acceleration disabled: $rc{kvm_err}\n"
            if     $args{v} 
               and $rc{kvm} eq 'no' 
               and $globals{action_name} =~ m/start|restore/; 

        $globals{top_owner}    = get_topology_owner();
        $globals{ipaddr}       = get_ipaddr();
    
        # most actions take vms as params, but some do not and need 'cleaning'
        #######################################################################
        # NOTE: @{ $globals{action_params} } always contains a list of vms; 
        # weird params for certain actions are stored elsewhere 
        # (i.e. @<action>_params, where <action> refers to the action name, 
        # e.g. @monitor_params
        #######################################################################
    
        @{ $globals{action_params} } = clean_action_params( @params );
    
        # are the switches sane?
        chk_options();                      # this sub dies when appropriate
    
        # initialize topology, more or less depending on action
        ########################################################
    
        # certain actions are not topology specific
        my @certain_actions = qw( all running config help unset backup design );
    
        # but the remaining actions do need a topology specified, so: 
        unless ( grep { $globals{action_name} eq $_ } @certain_actions ) {
            $globals{topology_name} = get_topology_name();
            copy_topology_file() unless $globals{topology_name} eq 'default';
        }
        lock_hash( %globals );

        # certain actions need a topology fully initialized: 
        @certain_actions = qw(
            start restore status stop save suspend resume show disks destroy
            connect disconnect ps kill rmcable top check chk dup pause migrate 
            monitor basify
        );
        if ( grep { $globals{action_name} eq $_ } @certain_actions ) {

            # err msgs emitted by chk_topology(), which is called by 
            # init_topology() 
            init_topology() or exit 1;

            # if we using dialog, then allow user to specify machines: 
            my $status = "";
            if ( $globals{dialog_loop} ) {
                # tedious to choose vms for status action: 
                $status = dialog_choose_vms() 
                    unless $globals{action_name} eq 'status'; 
                if ( $status eq 'CANCEL' ) { 
                    # go back one level in the dialog: 
                    unlock_hash( %globals ); 
                    warn "DEBUG: ", __FILE__, " redo-ing dialog loop at line ", 
                                    __LINE__, "\n" 
                        if $args{d}; 
                    redo LOOP; 
                }
            }
        }


        # die if the action is disabled:     
        if ( grep { $globals{action_name} eq $_ } keys %disabled_actions ) {
            my $dep = $disabled_actions{ $globals{action_name} };
            Die "$globals{action_name} action disabled: missing $dep\n";
        } 

        # action has been specified, action parameters have been specified
        # (if applicable), not disabled, so do the action 
        ###################################################################

        $action2sub{ $globals{action_name} }->();

        # if we're in a dialog loop, things are more complicated:
        ##########################################################

        if ( $globals{dialog_loop} ) {
            if ( $output ) {  # the action produced output 
                if ( $globals{action_name} =~ m/^(running)|(all)$/ ) { 
                    # allow user to choose topology from list in output: 
                    my $retval = 
                        dialog_set_from_list( 
                            'Set topology from list', 
                            split('\n', $output) 
                        );
                    unlock_hash( %globals ); 
                    if ( $retval eq 'CANCEL' ) {
                        # go back one level in dialog: 
                        warn "DEBUG: ", __FILE__, 
                             " redo-ing dialog loop at line ", 
                                        __LINE__, "\n" 
                            if $args{d}; 
                        redo LOOP; 
                    }
                    $globals{topology_name} = $args{f} = $retval; 
                    $globals{action_name} = 'set'; 
                    lock_hash( %globals ); 
                    close( $output_fh ); 
                    open( $output_fh, '>', \$output )
                        or Die "cannot redirect STDERR: $!\n";
                    $action2sub{ $globals{action_name} }->();
                }
                elsif ( $globals{action_name} eq 'diagram' ) { 
                    # dialog mangles diagram: restore stdout 
                    select STDOUT;
                    close $output_fh;                
                    my $clear = `clear`;  # TODO: using external program here
                    print $clear;
                    print "$globals{topology_name}\n", 
                          '=' x (length($globals{topology_name}) +1),
                          "\n\n",
                           $output,
                          "\n[any key to return to menu] "; 
                    <STDIN>;
                    print $clear;
                }
                else {   # do the following for remaining actions
                    # print redirected STDOUT to dialog msgbox:
                    my $nlines = split( "\n", $output );
                    my $d = new UI::Dialog (
                        backtitle => 'Vinetctl',
                        title =>   "$globals{topology_name}: output for "
                                 . "'$globals{action_name}' action: ", 
                        width => 80, 
                        height => $nlines+6, 
                        listheight => $nlines+4, 
                        order => [ 'CDialog', 'Whiptail' ], 
                    ) ;
                    $d->msgbox( text => $output ); 
                }
            }
            else {  # action produced no output
                my $d = new UI::Dialog (
                    backtitle => 'Vinetctl',
                    title =>   "$globals{topology_name}: output for "
                             . "'$globals{action_name}' action: ", 
                    height => 6, 
                    order => [ 'CDialog', 'Whiptail' ], 
                );
                $d->msgbox( text => "No topologies matched your query\n" ); 
            }
            # restore STDOUT
            select STDOUT; 
            close $output_fh;
        }
    
        # cleanup
        ##########
    
        # for certain actions, loop through nics and destroy vde wires
        @certain_actions = qw( kill destroy stop );
        destroy_dead_wires() if grep { $globals{action_name} eq $_ } 
                                     @certain_actions;

        # dialog functions sometimes set %args, so unset it each loop
        foreach ( keys %args ) {
            undef $args{$_} unless $_ eq 'f'; 
        }

        # repeat this loop if we're doing a dialog
        if ( $globals{dialog_loop} ) { 
            # we lock this hash in the loop, but need to unlock if redo-ing: 
            unlock_hash( %globals );
            warn "DEBUG: ", __FILE__, " redo-ing dialog loop at line ", 
                            __LINE__, "\n" 
                if $args{d}; 
            redo LOOP; 
        }
    }     # LOOP

    return( report_retval() );
}

# get_dispatch_table(): hashref as arg, populates it with a mapping between
# action names and subrefs to the corresponding subroutine
#############################################################################

sub get_dispatch_table {
    report_calling_stack(@_) if $args{d};

    my $action2sub = shift;

    %{ $action2sub } = (
        'all'         => \&all_action,
        'running'     => \&running_action,
        'config'      => \&config_action,
        'help'        => \&help_action,
        'unset'       => \&unset_action,
        'ports'       => \&ports_action,
        'grant'       => \&grant_action,
        'set'         => \&set_action,
        'list'        => \&list_action,
        'ls'          => \&list_action,
        'reset'       => \&reset_action,
        'diagram'     => \&show_diag_action,
        'start'       => \&start_restore_action,
        'restore'     => \&start_restore_action,
        'status'      => \&status_action,
        'stop'        => \&stop_save_suspend_resume_action,
        'save'        => \&stop_save_suspend_resume_action,
        'suspend'     => \&stop_save_suspend_resume_action,
        'pause'       => \&stop_save_suspend_resume_action,
        'resume'      => \&stop_save_suspend_resume_action,
        'show'        => \&show_diag_action,
        'disks'       => \&disks_action,
        'destroy'     => \&destroy_action,
        'connect'     => \&connect_action,
        'disconnect'  => \&disconnect_action,
        'ps'          => \&ps_kill_action,
        'kill'        => \&ps_kill_action,
        'rmcable'     => \&rmcable_action,
        'top'         => \&top_action,
        'cat'         => \&cat_action,
        'backup'      => \&backup_action,
        'dup'         => \&dup_action,
        'undup'       => \&undup_action,
        'check'       => \&check_action,
        'chk'         => \&check_action,
        'monitor'     => \&monitor_action,
        'migrate'     => \&migrate_action, 
        'edit'        => \&edit_action, 
        'standalone'  => \&dialog_standalone_action,
        'install'     => \&dialog_install_action, 
#        'design'      => \&design_action, 
#        'basify'      => \&basify_action, 
    );
    lock_hash( %{ $action2sub } );

    return( report_retval() );    
}

# disable_actions(): disable an action if external prog dependencies missing
#############################################################################

sub disable_actions {

    my %disabled_actions; 

    # disable actions for which we do not have necessary external programs
    -e $rc{rsync}    or $disabled_actions{backup}  = "$rc{rsync}";
    -e $rc{top}      or $disabled_actions{top}     = "$rc{top}";
    -e $rc{unixterm} or -e $rc{socat} 
                     or $disabled_actions{monitor} = "$rc{unixterm} or $rc{socat}";
    -e $rc{ssh}      or $disabled_actions{migrate} = "$rc{ssh}";

    return( \%disabled_actions );
}

1;
