package Vinetctl::GrantAction;

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
use constant { TRUE => 1, FALSE => 0 };
use Fcntl qw( :mode ); 

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

use Vinetctl::Util qw(
    my_system
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    grant_action
);

# grant_action(): grant another user access to a running topology
##################################################################

sub grant_action {
    report_calling_stack(@_) if $args{d};

    Die "usage: $rc{progname} [-f TOP] $globals{action_name} PERMS\n"
        unless @{ $globals{action_params} } < 2;

    my @params = @{ $globals{action_params} }; 
    my $perms = $params[0];
    if    ( $rc{grant_type} eq 'acls' )   { do_grant_acls( $perms ) }
    elsif ( $rc{grant_type} eq 'groups' ) { do_grant_groups( $perms ) }
    else { Die "unsupported grant type: $rc{grant_type}" }

    return( report_retval() ); 
}

# do_grant_groups(): grant other users access to topology using unix groups
############################################################################

sub do_grant_groups {
    report_calling_stack(@_) if $args{d};

    my $sock_file = 
        "$rc{tmux_sock_prefix}-$globals{topology_name}";
    -e $sock_file 
        or Die "session $sock_file does not exist\n";

    my $param = shift // 0;

    my @stats = stat( $sock_file );
    my( $sock_file_mode, $sock_file_gid ) = 
        ( $stats[2], $stats[5] );

    # group owner of tmux socket:
    my $sock_file_group = getgrgid( $sock_file_gid );

    # group have rw? 
    my $sock_file_g_rw = 
        ( $sock_file_mode & (S_IRGRP | S_IWGRP) ) >> 3;

    my @gidlist = getgroups();               # list of groups we belong to

    if ( $param ) {
        my $group = $param =~ s/^-//r;       # keep '-' with non-dest s//
        my $gid = getgrnam($group);
        defined $gid or Die "group $param does not exist\n";
        grep { $_ == $gid } @gidlist
            or Die "you are not a member of $param\n";

        my $revoke = FALSE;
        if ( $param =~ s/^-// ) {                                # revoke
            chmod 0600, $sock_file 
                if $sock_file_group eq $group;
            $revoke = TRUE;
        } 
        else {                                                   # grant
            chown -1, scalar $gid, $sock_file;
            chmod 0660, $sock_file;
        }
        say "ok", $revoke ? 
            " (use the disconnect action to remove existing sessions)" :
            "";
    } 
    else { say $sock_file_group if $sock_file_g_rw }

    return( report_retval() );
}

# do_grant_acls(): grant other users access to topology
########################################################

sub do_grant_acls { 
    report_calling_stack(@_) if $args{d};

#    my $ExtAttr = TRUE;
#    unless ( eval {require File::ExtAttr} ) { 
#        Warn "File::ExtAttr unavailable\n" if $args{d};
#        $ExtAttr = FALSE;
#    }
    
    my $sock_file = "$rc{tmux_sock_prefix}-$globals{topology_name}";
    my $perms = shift // 0;

    my $ExtAttr = FALSE; 
    if ( $ExtAttr ) { 

        # use perl's File::ExtAttr
        Die "use of perlmod ExtAttr not implemented; use facl cms\n"  ## TODO

    } 
    else { 

        # use getfacl(1) and setfacl(1)
        ################################

	if ( not $perms ) { 

            # show perms with getfacl
            ##########################

            my @users; 
            open( my $fh, '-|', "$rc{getfacl} $sock_file 2>/dev/null" )
                or Warn "grant: cannot open $sock_file: $!\n";
            while(<$fh>) {
                next unless /^user:[^:]/;
                my( undef, $user, undef ) = split ':';
                push @users, $user;
	    }
            close $fh;
            if ( @users ) {
                print "$globals{topology_name}: ";
                print "$_ " foreach @users;
                print "\n";
            }
        } 
        else { 

            # set perms with setfacl
            #########################

            -e $sock_file 
                or Die "session $sock_file does not exist\n";

            my $revoke = FALSE;    # assume we're granting, not revoking 

            USER: foreach my $user ( split ',', $perms ) {  # got user list

                # nondestructive regex: 
                getpwnam( $user =~ s/^[-+]?([a-z0-9]+)$/$1/r ) 
                    or Die "getpwnam failed on $user.  Do they exist?\n";

                # revoke access:
                if ( $user =~ s/^-// ) { 
                    $revoke = TRUE;
                    my_system( "$rc{setfacl} -x u:$user: $sock_file" );
                } 
                # grant access:
                else {
                    $user =~ s/^[+]//; 
                    my_system( "$rc{setfacl} -m u:$user:rw $sock_file" ) 
                }
            }

            say "ok", $revoke ? 
                " (use the disconnect action to remove existing sessions)" :
                "";
        }

    }

    return( report_retval() );
}

1;
