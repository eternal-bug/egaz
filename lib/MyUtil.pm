package MyUtil;
use strict;
use warnings;
use autodie;

use Carp;
use Path::Tiny;

use base 'Exporter';
use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);
@ISA = qw(Exporter);

%EXPORT_TAGS = (
    all => [
        qw{
            read_fasta exec_cmd
            },
    ],
);

@EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

sub read_fasta {
    my $filename = shift;

    my @lines = path($filename)->lines( { chomp => 1,});

    my @seq_names;
    my %seqs;
    for my $line (@lines) {
        if ( $line =~ /^\>[\w:-]+/ ) {
            $line =~ s/\>//;
            push @seq_names, $line;
            $seqs{$line} = '';
        }
        elsif ( $line =~ /^[\w-]+/ ) {
            $line =~ s/[^\w-]//g;
            my $seq_name = $seq_names[-1];
            $seqs{$seq_name} .= $line;
        }
        else {    # Blank line, do nothing
        }
    }

    return ( \%seqs, \@seq_names );
}

# in situ convert reference of string to string
# For the sake of efficiency, the return value should be discarded
sub _ref2str {
    my $ref = shift;

    if ( ref $ref eq "REF" ) {
        $$ref = $$$ref;    # this is very weird, but it works
    }

    unless ( ref $ref eq "SCALAR" ) {
        carp "Wrong parameter passed\n";
    }

    return $ref;
}

sub exec_cmd {
    my $cmd = shift;

    print "\n", "-" x 12, "CMD", "-" x 15, "\n";
    print $cmd , "\n";
    print "-" x 30, "\n";

    system $cmd;
}
