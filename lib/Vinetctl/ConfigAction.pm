package Vinetctl::ConfigAction;

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

use Vinetctl::Globals qw( 
    %args
    %rc
    %globals
);

use Vinetctl::Debug qw( 
    report_calling_stack
    report_retval
    Die
);

use Exporter qw( import );
our @EXPORT_OK = qw( 
    config_action
);

# config_action(): show program's run config
#############################################

sub config_action {
    report_calling_stack(@_) if $args{d};

    Die "usage: $rc{progname} $globals{action_name}\n" 
        if @{ $globals{action_params} };

    # populate @config
    ###################

    my @config;     # list of strings of the form: key=value
    RC: foreach my $key ( sort keys %rc ) {
        if ( not ref($rc{$key}) ) { 
            push @config, "$key=$rc{$key}" 
        }
        elsif ( ref($rc{$key}) eq "ARRAY" ) { 
            next RC;     # skip arrays
#            my $string = "$key=";
#            foreach my $element ( @{ $rc{$key} } ) {
#                $string .= "$element,"
#            }
#            push @config, $string;
        } 
        else { 
            Die "BUG: rc hash has values that are refs but not arrays\n" 
        }
    }

    # print @config
    ################

    say foreach @config;

    return( report_retval() );
}

1;
