package Vinetctl::Tmux;

use strict;
use warnings;
use constant { TRUE => 1, FALSE => 0 };
use Fcntl qw( :mode );

use Vinetctl::Debug qw( 
    Warn
    Die
    report_calling_stack
    report_retval
);

use Vinetctl::Globals qw( 
    %args
    %rc
    %globals
);

use Vinetctl::Util qw(
    my_system
    get_uid
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    get_tmux_conf 
    tmux_new_session 
    tmux_cmd 
    tmux_has_session 
    tmux_detach 
    tmux_list_windows 
    tmux_attach 
    get_tmux_sock
    got_gidperms_tmux_sock
    get_tmux_socks_of_user
);

# get_tmux_conf(): restricted tmux settings for newbies
########################################################

sub get_tmux_conf {
    report_calling_stack(@_) if $args{d};

#######################################
    my $tmux_conf = <<"    TMUX_CONF";
unbind-key -a
bind-key C-b send-prefix
bind-key 1 select-window -t :1
bind-key 2 select-window -t :2
bind-key 3 select-window -t :3
bind-key 4 select-window -t :4
bind-key 5 select-window -t :5
bind-key 6 select-window -t :6
bind-key 7 select-window -t :7
bind-key 8 select-window -t :8
bind-key 9 select-window -t :9
bind-key : command-prompt
bind-key [ copy-mode
bind-key ] paste-buffer
bind-key d detach-client
bind-key l last-window
bind-key n next-window
bind-key p previous-window
bind-key w choose-window
set-option -g status-left-length 40
set-option -g status-right 'vinetctl     '
    TMUX_CONF
#######################################

    return( report_retval($tmux_conf) );
}

# tmux_new_session(): create new tmux session
##############################################

sub tmux_new_session { 
    report_calling_stack(@_) if $args{d};

    my( $sock, $target_session, $target ) = @_;
    my $retval = 1;      # assume success

    # how to invoke tmux:
    #####################

    my @options = (
        -f => $rc{tmux_conf}, -S => $sock, 'new-session', '-d',
        -s => $target_session
    );
    push @options, -t => $target 
        if defined $target;

    # don't specify conf file with -f if there is no conf file
    ###########################################################

    unless ( -e $rc{tmux_conf} ) {
        splice @options, 0, 2;
        Warn "$rc{tmux_conf} doesn't exist, using defaults.\n"
            if $args{d};
    }

    # start up the new tmux session
    ################################

    unless ( my_system("$rc{tmux} @options 2>> $rc{log_file}") == 0 ) {
        Warn "unable to create $target_session: system() failed\n"
            if $args{d}; 
        $retval = 0;
    }

    # don't cripple tmux if conf file exists, or if user overrode
    ##############################################################

    unless ( -e $rc{tmux_conf} or $args{t} ) {
        my $tmux_conf = get_tmux_conf();
        open my $conf, '<', \$tmux_conf;
        while (<$conf>) {
            chomp;
            system( "$rc{tmux} -S $sock $_ >> $rc{log_file} 2>&1" );
        }
    }

    return( report_retval($retval) );
}

# tmux_cmd(): a generic tmux cmd wrapper
#########################################

sub tmux_cmd { 
    report_calling_stack(@_) if $args{d};

    my( $sock, $target, $cmd ) = @_;
    my @options = ( -S => $sock, $cmd, -t => $target );
    my_system( "$rc{tmux} @options 2>> $rc{log_file}" );

    return( report_retval() );
}

# tmux_has_session: returns true if a tmux session exists
##########################################################

sub tmux_has_session { 
    report_calling_stack(@_) if $args{d};

    my( $sock, $target ) = @_;
    my @options = ( -S => $sock, 'has-session', -t => $target );

    my $retval = my_system( "$rc{tmux} @options 2>> $rc{log_file}" ) 
               ? 0 
               : 1;

    return( report_retval($retval) );
}

# tmux_detach(): detaches a tmux session
#########################################

sub tmux_detach { 
    report_calling_stack(@_) if $args{d};

    my( $sock, $session ) = @_;
    my @options = ( -S => $sock, 'detach', -s => $session );
    my_system( "$rc{tmux} @options 2>> $rc{log_file}" );

    return( report_retval() );
}

# tmux_list_windows(): lists the windows in a tmux session
###########################################################

sub tmux_list_windows { 
    report_calling_stack(@_) if $args{d};

    my( $sock, $target ) = @_;
    my @options = ( -S => $sock, 'list-windows', -t => $target );
    my_system( "$rc{tmux} @options >> $rc{log_file} 2>&1" ); 
    my $retval = $? > 0 ? 0 : 1; 

    return( report_retval($retval) );
}

# tmux_attach(): connect to a tmux session
###########################################

sub tmux_attach { 
    report_calling_stack(@_) if $args{d};

    my( $mode, $sock, $target, $detach ) = @_;
    my @options = ( -S => $sock, 'attach', -t => $target );

    push @options, '-r' 
        if $mode eq 'ro';
    push @options, '-d' 
        if $detach;

    # we unlink pid file since we won't run exit handler at END of vinetctl
    unlink $globals{pid_file}
        or Warn "cannot unlink $globals{pid_file}: $!\n";

    exec( "$rc{tmux}", @options )
        or Die "couldn't exec '$rc{tmux} @options': $!\n"; 

    # no return!
}

# get_tmux_sock(): return tmux socket given topology owner and name
####################################################################

sub get_tmux_sock { 
    report_calling_stack(@_) if $args{d};

    my $sock;

    # determine name of socket file when accessing another user's topology
    #######################################################################

    if ( $globals{top_owner} ne $rc{username} ) { 

        my $uid = ( getpwnam($globals{top_owner}) )[2] 
            or Die "getpwnam() failed: $globals{top_owner}: $!\n";

        $sock = "/tmp/$rc{progname}-${uid}-$globals{topology_name}"; 

        Die "$globals{top_owner} is not running any topologies in $sock\n"
            unless -e $sock;

        # check whether we have access to this user's topology
        #######################################################

        if ( $rc{grant_type} eq 'acls' ) { 

            # acls
            ######

            open( my $fh, '-|', "$rc{getfacl} $sock 2>/dev/null" )
                or Die "$rc{getfacl}: cannot check $sock:$!\n";
            my @perms = <$fh>;
            close $fh;

            Die "$globals{action_name}: $sock: permission denied\n"
                unless grep { /user:$rc{username}:rw-/ } @perms;
        } 
        else { 

            # groups
            ########

            Die "$globals{action_name}: $sock: permission denied\n"
                unless got_gidperms_tmux_sock( $sock );

        }

    }

    # if $sock is undefined then we're working with our own topology
    #################################################################

    $sock //= "$rc{tmux_sock_prefix}-$globals{topology_name}";

    -e $sock or Die "$sock: no such socket\n";

    # need 'filetest' pragma to test using ACLs:
    #############################################

    {  use filetest 'access';
       -w $sock or Die "$sock: permission denied\n";
    }

    return( report_retval($sock) );
}

# got_gidperms_tmux_sock(): return true if we have group rw on sock file
#########################################################################

sub got_gidperms_tmux_sock {
    report_calling_stack(@_) if $args{d};

    my $sock_file = shift;
    my @stats = stat( $sock_file );
    my( $sock_file_mode, $sock_file_gid ) = ( $stats[2], $stats[5] );

    # does the group owner have rw?
    ################################

    my $sock_file_g_rw = ( $sock_file_mode & (S_IRGRP | S_IWGRP) ) >> 3;
    my $retval = 
        ( grep { $_ == $sock_file_gid } getgroups() ) ? TRUE : FALSE; 

    return( report_retval($retval) );
}

# get_socks_to_chk(): return a user's tmux sockets
###################################################

sub get_tmux_socks_of_user { 
    report_calling_stack(@_) if $args{d};

    my( @socks_to_chk, $perms );
    my $uid = get_uid( $globals{top_owner} );

    if ( $globals{top_owner} ne $rc{username} ) { 

        # another user: get all vinetctl related tmux sockets for this user
        ####################################################################

        my @usocks = glob qq("$rc{tmux_sock_dir}/$rc{progname}-${uid}-*")
            or return( report_retval(0) ); # no socks, so no running tops

        SOCK: foreach my $usock ( @usocks ) { 

            # add it to the list if we have permission to read the socket
            #############################################################

            my $perms;
            if ( $rc{grant_type} eq 'acls' ) {
                # acls
                my $cmd = join(' ', $rc{getfacl}, $usock, '2>/dev/null', 
                               '|',  "grep user:$rc{username}:rw-"       );
                $perms = `$cmd`;
            } 
            else { 
                # unix groups
                $perms = got_gidperms_tmux_sock( $usock ) ? TRUE : FALSE;
            }
            if    ( $perms   ) { push @socks_to_chk, $usock }
            elsif ( $args{d} ) { Warn "$usock: permission denied\n" }
        }
    } 
    else { 

        # this user
        ###########

        @socks_to_chk = glob qq("$rc{tmux_sock_prefix}-*"); 
    } 

    return( report_retval(@socks_to_chk) );
}

1;
