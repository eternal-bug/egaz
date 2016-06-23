#!/usr/bin/perl
use strict;
use warnings;
use autodie;

use Getopt::Long;
use Config::Tiny;
use FindBin;
use YAML::Syck;

use DBI;
use Text::CSV_XS;
use DateTime::Format::Natural;
use List::MoreUtils qw(any all uniq);
use Template;

use Path::Tiny;
use File::Find::Rule;

use AlignDB::Stopwatch;

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#
my $Config = Config::Tiny->read("$FindBin::RealBin/../config.ini");

# record ARGV and Config
my $stopwatch = AlignDB::Stopwatch->new(
    program_name => $0,
    program_argv => [@ARGV],
    program_conf => $Config,
);

=head1 NAME

strain_bz_self.pl - Full procedure for self genome alignments.

=head1 SYNOPSIS

    perl strain_bz_self.pl [options]
      Options:
        --help          -?          brief help message
        --working_dir   -w  STR     Default is [.]
        --seq_dir       -s  STR     Will do prep_fa() from this dir or use seqs store in $working_dir
        --target        -t  STR
        --queries       -q  @STR
        --csv_taxon     -c  STR     All taxons in this project (may also contain unused taxons)
        --length            INT     Minimal length of paralogous fragments
        --name_str      -n  STR     Default is []
        --parted                    Sequences are partitioned
        --noblast                   Don't blast against genomes
        --msa               STR     Aligning program for refine. Default is [mafft]
        --norm                      RepeatMasker has been done.
        --nostat                    Don't do stat stuffs
        --norawphylo                Skip rawphylo
        --parallel          INT     number of child processes

=cut

my $aligndb = path( $FindBin::RealBin, "..", "alignDB" )->absolute->stringify;
my $egaz = path($FindBin::RealBin)->absolute->stringify;

GetOptions(
    'help|?' => sub { Getopt::Long::HelpMessage(0) },
    'working_dir|w=s' => \( my $working_dir = "." ),
    'seq_dir|s=s'     => \my $seq_dir,
    'target|t=s'      => \my $target,
    'queries|q=s'     => \my @queries,
    'csv_taxon|c=s'   => \my $csv_taxon,
    'length=i'        => \( my $length      = 1000 ),
    'name_str|n=s'    => \( my $name_str    = "working" ),
    'parted'          => \my $parted,
    'noblast'         => \my $noblast,
    'msa=s'           => \( my $msa         = 'mafft' ),
    'norm'            => \my $norm,
    'nostat'          => \my $nostat,
    'parallel=i'      => \( my $parallel    = $Config->{run}{parallel} ),
) or Getopt::Long::HelpMessage(1);

#----------------------------------------------------------#
# init
#----------------------------------------------------------#
$stopwatch->start_message("Writing strains summary...");

# prepare working dir
{
    print "Working on $name_str\n";
    $working_dir = path( $working_dir, $name_str )->absolute;
    $working_dir->mkpath;
    $working_dir = $working_dir->stringify;
    print " " x 4, "Working dir is $working_dir\n";

    path( $working_dir, 'Genomes' )->mkpath;
    path( $working_dir, 'Pairwise' )->mkpath;
    path( $working_dir, 'Processing' )->mkpath;
    path( $working_dir, 'Results' )->mkpath;
}

# build basic information
my @data;
{
    my %taxon_of;
    if ($csv_taxon) {
        for my $line ( path($csv_taxon)->lines ) {
            my @fields = split /,/, $line;
            if ( $#fields >= 2 ) {
                $taxon_of{ $fields[0] } = $fields[1];
            }
        }
    }
    @data = map {
        {   name  => $_,
            taxon => exists $taxon_of{$_} ? $taxon_of{$_} : 0,
            dir   => path( $working_dir, 'Genomes', $_ )->stringify,
        }
    } ( $target, @queries );
}

# if seqs is not in working dir, copy them from seq_dir
if ($seq_dir) {
    print "Get seqs from [$seq_dir]\n";

    for my $id ( $target, @queries ) {
        print " " x 4 . "Copy seq of [$id]\n";

        my $original_dir = path( $seq_dir, $id )->stringify;
        my $cur_dir = path( $working_dir, 'Genomes', $id );
        $cur_dir->mkpath;
        $cur_dir = $cur_dir->stringify;

        my @fa_files
            = File::Find::Rule->file->name( '*.fna', '*.fa', '*.fas',
            '*.fasta' )->in($original_dir);

        printf " " x 8 . "Total %d fasta file(s)\n", scalar @fa_files;

        for my $fa_file (@fa_files) {
            my $basename = prep_fa( $fa_file, $cur_dir );

            my $gff_file = path( $original_dir, "$basename.gff" );
            if ( $gff_file->is_file ) {
                $gff_file->copy($cur_dir);
            }
            my $rm_gff_file = path( $original_dir, "$basename.rm.gff" );
            if ( $rm_gff_file->is_file ) {
                $rm_gff_file->copy($cur_dir);
            }
        }
    }
}

{
    my $tt = Template->new;
    my $text;
    my $sh_name;

    #----------------------------#
    # all *.sh files
    #----------------------------#

    # real_chr.sh
    $sh_name = "1_real_chr.sh";
    print "Create $sh_name\n";
    $text = <<'EOF';
#!/bin/bash
cd [% working_dir %]

sleep 1;

echo "common_name,taxon_id,chr,length,assembly" > chr_length.csv

[% FOREACH item IN data -%]
# [% item.name %]
faops size [% item.dir %]/*.fa > [% item.dir %]/chr.sizes;
perl -aln -F"\t" -e 'print qq{[% item.name %],[% item.taxon %],$F[0],$F[1],}' [% item.dir %]/chr.sizes >> chr_length.csv;

[% END -%]

echo "==> chr_length.csv generated <=="

EOF
    $tt->process(
        \$text,
        {   data        => \@data,
            working_dir => $working_dir,
        },
        path( $working_dir, $sh_name )->stringify
    ) or die Template->error;

    # file-rm.sh
    if ( !$norm ) {
        $sh_name = "2_file_rm.sh";
        print "Create $sh_name\n";
        $text = <<'EOF';
#!/bin/bash
cd [% working_dir %]

sleep 1;

#----------------------------#
# Masking all fasta files
#----------------------------#
[% FOREACH item IN data -%]

for f in `find [% item.dir%] -name "*.fa"` ; do
    rename 's/fa$/fasta/' $f ;
done

for f in `find [% item.dir%] -name "*.fasta"` ; do
    RepeatMasker $f -xsmall --parallel [% parallel %] ;
done

for f in `find [% item.dir%] -name "*.fasta.out"` ; do
    rmOutToGFF3.pl $f > `dirname $f`/`basename $f .fasta.out`.rm.gff;
done

for f in `find [% item.dir%] -name "*.fasta"` ; do
    if [ -f $f.masked ];
    then
        rename 's/fasta.masked$/fa/' $f.masked;
        find [% item.dir%] -type f -name "`basename $f`*" | parallel --no-run-if-empty rm;
    else
        rename 's/fasta$/fa/' $f;
        echo `date` "RepeatMasker on $f failed.\n" >> RepeatMasker.log
        find [% item.dir%] -type f -name "`basename $f`*" | parallel --no-run-if-empty rm;
    fi;
done;

[% END %]

EOF

        $tt->process(
            \$text,
            {   data        => \@data,
                parallel    => $parallel,
                working_dir => $working_dir,
            },
            path( $working_dir, $sh_name )->stringify
        ) or die Template->error;
    }

    # self_cmd.sh
    $sh_name = "3_self_cmd.sh";
    print "Create $sh_name\n";
    $text = <<'EOF';
#!/bin/bash
# strain_bz_self.pl
# perl [% stopwatch.cmd_line %]

cd [% working_dir %]

sleep 1;

[% FOREACH id IN all_ids -%]
#----------------------------------------------------------#
# [% id %]
#----------------------------------------------------------#
if [ -d [% working_dir %]/Pairwise/[% id %]vsselfalign ]
then
    rm -fr [% working_dir %]/Pairwise/[% id %]vsselfalign
fi

#----------------------------#
# self bz
#----------------------------#
perl [% egaz %]/bz.pl \
    --is_self \
    -s set01 -C 0 --noaxt [% IF parted %]-tp -qp[% END %] \
    -dt [% working_dir %]/Genomes/[% id %] \
    -dq [% working_dir %]/Genomes/[% id %] \
    -dl [% working_dir %]/Pairwise/[% id %]vsselfalign \
    --parallel [% parallel %]

#----------------------------#
# lpcna
#----------------------------#
perl [% egaz %]/lpcna.pl \
    -dt [% working_dir %]/Genomes/[% id %] \
    -dq [% working_dir %]/Genomes/[% id %] \
    -dl [% working_dir %]/Pairwise/[% id %]vsselfalign \
    --parallel [% parallel %]

[% END -%]

EOF
    $tt->process(
        \$text,
        {   stopwatch   => $stopwatch,
            parallel    => $parallel,
            working_dir => $working_dir,
            egaz        => $egaz,
            parted      => $parted,
            name_str    => $name_str,
            all_ids     => [ $target, @queries ],
        },
        path( $working_dir, $sh_name )->stringify
    ) or die Template->error;

    # proc_cmd.sh
    $sh_name = "4_proc_cmd.sh";
    print "Create $sh_name\n";
    $text = <<'EOF';
#!/bin/bash
# perl [% stopwatch.cmd_line %]

cd [% working_dir %]

sleep 1;

[% FOREACH id IN all_ids -%]
#----------------------------------------------------------#
# [% id %]
#----------------------------------------------------------#
if [ -d [% working_dir %]/Processing/[% id %] ]
then
    find [% working_dir %]/Processing/[% id %] -type f -not -name "circos.conf" -and -not -name "karyotype*" \
        | parallel --no-run-if-empty rm
else
    mkdir -p [% working_dir %]/Processing/[% id %]
fi

if [ ! -d [% working_dir %]/Results/[% id %] ]
then
    mkdir -p [% working_dir %]/Results/[% id %]
fi

cd [% working_dir %]/Processing/[% id %]

#----------------------------#
# genome sequences
#----------------------------#
echo "* Recreate genome.fa"
sleep 1;
find [% working_dir %]/Genomes/[% id %] -type f -name "*.fa" \
    | sort | xargs cat \
    | perl -nl -e '/^>/ or $_ = uc; print' \
    > genome.fa
faops size genome.fa > chr.sizes

#----------------------------#
# Correct genomic positions
#----------------------------#
echo "* Get exact copies in the genome"
sleep 1;

echo "* axt2fas"
fasops axt2fas [% working_dir %]/Pairwise/[% id %]vsselfalign/axtNet/*.axt.gz \
    -l [% length %] -s chr.sizes -o stdout > axt.fas
fasops separate axt.fas -o [% working_dir %]/Processing/[% id %] --nodash -s .sep.fasta

echo "* Target positions"
perl [% egaz %]/sparsemem_exact.pl -f target.sep.fasta -g genome.fa \
    --length 500 --discard 50 -o replace.target.tsv
fasops replace axt.fas replace.target.tsv -o axt.target.fas

echo "* Query positions"
perl [% egaz %]/sparsemem_exact.pl -f query.sep.fasta -g genome.fa \
    --length 500 --discard 50 -o replace.query.tsv
fasops replace axt.target.fas replace.query.tsv -o axt.correct.fas

#----------------------------#
# Coverage stats
#----------------------------#
echo "* Coverage stats"
sleep 1;
fasops covers axt.correct.fas -o axt.correct.yml
runlist split axt.correct.yml -s .temp.yml
runlist compare --op union target.temp.yml query.temp.yml -o axt.union.yml
runlist stat --size chr.sizes axt.union.yml -o [% working_dir %]/Results/[% id %]/[% id %].union.csv

# links by lastz-chain
fasops links axt.correct.fas -o stdout \
    | perl -nl -e 's/(target|query)\.//g; print;' \
    > links.lastz.tsv

# remove species names
# remove duplicated sequences
# remove sequences with more than 250 Ns
fasops separate axt.correct.fas --nodash --rc -o stdout \
    | perl -nl -e '/^>/ and s/^>(target|query)\./\>/; print;' \
    | faops filter -u stdin stdout \
    | faops filter -n 250 stdin stdout \
    > axt.gl.fasta

[% IF noblast -%]
#----------------------------#
# Lastz paralogs
#----------------------------#
cat axt.gl.fasta > axt.all.fasta
[% ELSE -%]
#----------------------------#
# Get more paralogs
#----------------------------#
echo "* Get more paralogs"
perl [% egaz %]/fasta_blastn.pl  -f axt.gl.fasta -g genome.fa -o axt.bg.blast --parallel [% parallel %]
perl [% egaz %]/blastn_genome.pl -f axt.bg.blast -g genome.fa -o axt.bg.fasta -c 0.95 --parallel [% parallel %]
cat axt.gl.fasta axt.bg.fasta \
    | faops filter -u stdin stdout \
    | faops filter -n 250 stdin stdout \
    > axt.all.fasta
[% END -%]

#----------------------------#
# Link paralogs
#----------------------------#
echo "* Link paralogs"
sleep 1;
perl [% egaz %]/fasta_blastn.pl   -f axt.all.fasta -g axt.all.fasta -o axt.all.blast --parallel [% parallel %]
perl [% egaz %]/blastn_paralog.pl -f axt.all.blast -c 0.95 -o links.blast.tsv --parallel [% parallel %]

#----------------------------#
# Merge paralogs
#----------------------------#
echo "* Merge paralogs"
sleep 1;

perl [% egaz %]/merge_node.pl -v -c 0.95 -o [% id %].merge.yml --parallel [% parallel %] \
[% IF noblast -%]
    -f links.lastz.tsv
[% ELSE -%]
    -f links.lastz.tsv -f links.blast.tsv
[% END -%]

perl [% egaz %]/paralog_graph.pl -v -m [% id %].merge.yml --nonself -o [% id %].merge.graph.yml \
[% IF noblast -%]
    -f links.lastz.tsv
[% ELSE -%]
    -f links.lastz.tsv -f links.blast.tsv
[% END -%]

echo "* CC sequences and stats"
perl [% egaz %]/cc.pl           -f [% id %].merge.graph.yml
perl [% egaz %]/proc_cc_chop.pl -f [% id %].cc.raw.yml --size chr.sizes --genome genome.fa --msa [% msa %] --parallel [% parallel %]
perl [% egaz %]/proc_cc_stat.pl -f [% id %].cc.yml --size chr.sizes

echo "* Coverage figure"
runlist stat --size chr.sizes [% id %].cc.chr.runlist.yml;
perl [% egaz %]/cover_figure.pl --size chr.sizes -f [% id %].cc.chr.runlist.yml;

#----------------------------#
# result
#----------------------------#
echo "* Results"
sleep 1;

mv [% id %].cc.pairwise.fas         [% working_dir %]/Results/[% id %]/[% id %].pairwise.fas
cp [% id %].cc.yml                  [% working_dir %]/Results/[% id %]
mv [% id %].cc.csv                  [% working_dir %]/Results/[% id %]/[% id %].copy.csv
mv [% id %].cc.runlist.yml          [% working_dir %]/Results/[% id %]/[% id %].copy.runlist.yml
mv [% id %].cc.chr.runlist.yml.csv  [% working_dir %]/Results/[% id %]/[% id %].chr.csv
mv [% id %].cc.chr.runlist.yml      [% working_dir %]/Results/[% id %]/[% id %].chr.runlist.yml
mv [% id %].cc.chr.runlist.png      [% working_dir %]/Results/[% id %]/[% id %].chr.png

#----------------------------#
# clean
#----------------------------#
echo "* Clean up"
sleep 1;

find [% working_dir %]/Processing/[% id %] -type f -name "*genome.fa*"   | parallel --no-run-if-empty rm
find [% working_dir %]/Processing/[% id %] -type f -name "*gl.fasta*"    | parallel --no-run-if-empty rm
find [% working_dir %]/Processing/[% id %] -type f -name "*.sep.fasta"   | parallel --no-run-if-empty rm
find [% working_dir %]/Processing/[% id %] -type f -name "axt.*"         | parallel --no-run-if-empty rm
find [% working_dir %]/Processing/[% id %] -type f -name "replace.*.tsv" | parallel --no-run-if-empty rm
find [% working_dir %]/Processing/[% id %] -type f -name "*.temp.yml"    | parallel --no-run-if-empty rm

[% END -%]
EOF
    $tt->process(
        \$text,
        {   stopwatch   => $stopwatch,
            parallel    => $parallel,
            working_dir => $working_dir,
            egaz        => $egaz,
            msa         => $msa,
            noblast     => $noblast,
            name_str    => $name_str,
            all_ids     => [ $target, @queries ],
            data        => \@data,
            length      => $length,
        },
        path( $working_dir, $sh_name )->stringify
    ) or die Template->error;

    # circos.conf
    $text = <<'EOF';
<image>
dir*   = [% working_dir %]/Results/[% id %]
file*  = [% id %].circos.png
background*     = white

# radius of inscribed circle in image
radius         = 1500p
background     = white

# by default angle=0 is at 3 o'clock position
angle_offset   = -90

24bit             = yes
auto_alpha_colors = yes
auto_alpha_steps  = 5
</image>

karyotype = karyotype.[% id %].txt
chromosomes_units = 1000

chromosomes_display_default = yes

<links>

<link>
file          = [% id %].cc.link4.txt
radius        = 0.88r
bezier_radius = 0.2r
color         = purple
thickness     = 2
ribbon        = yes
stroke_color  = purple
stroke_thickness = 2
</link>

<link>
file          = [% id %].cc.link3.txt
radius        = 0.88r
bezier_radius = 0.1r
color         = dgreen
thickness     = 3
ribbon        = yes
stroke_color  = dgreen
stroke_thickness = 2
</link>

<link>
file          = [% id %].cc.link2.txt
radius        = 0.88r
bezier_radius = 0r
color         = dorange
thickness     = 3
ribbon        = yes
stroke_color  = dorange
stroke_thickness = 2
</link>

</links>

<highlights>

<highlight>
file = highlight.features.[% id %].txt
r0 = 0.95r
r1 = 0.98r
</highlight>

<highlight>
file = highlight.repeats.[% id %].txt
r0 = 0.93r
r1 = 0.98r
</highlight>

<highlight>
file = [% id %].cc.linkN.txt
r0 = 0.89r
r1 = 0.92r
stroke_thickness = 2
stroke_color = grey
</highlight>

</highlights>

<ideogram>

<spacing>
    default = 0r
</spacing>

# thickness (px) of chromosome ideogram
thickness        = 20p
stroke_thickness = 2p

# ideogram border color
stroke_color     = dgrey
fill             = yes

# the default chromosome color is set here and any value
# defined in the karyotype file overrides it
fill_color       = black

# fractional radius position of chromosome ideogram within image
radius         = 0.85r
show_label     = no
label_font     = condensedbold
label_radius   = dims(ideogram,radius) + 0.05r
label_size     = 36

label_parallel   = yes

show_bands            = yes
fill_bands            = yes
band_stroke_thickness = 2
band_stroke_color     = white
band_transparency     = 1

</ideogram>

show_ticks       = yes
show_tick_labels = yes

show_grid        = no
grid_start       = dims(ideogram,radius_inner)-0.5r
grid_end         = dims(ideogram,radius_inner)

<ticks>
    skip_first_label           = yes
    skip_last_label            = no
    radius                     = dims(ideogram,radius_outer)
    tick_separation            = 2p
    min_label_distance_to_edge = 0p
    label_separation           = 5p
    label_offset               = 2p
    label_size                 = 8p
    multiplier                 = 0.001
    color                      = black
    show_label                 = no

<tick>
    spacing        = 10u
    size           = 8p
    thickness      = 2p
    color          = black
    grid           = yes
    grid_color     = grey
    grid_thickness = 1p
</tick>

<tick>
    spacing        = 100u
    size           = 8p
    thickness      = 2p
    color          = black
    grid           = yes
    grid_color     = dgrey
    grid_thickness = 1p
</tick>

</ticks>

<<include etc/colors_fonts_patterns.conf>>

<<include etc/housekeeping.conf>>

EOF
    for my $id ( $target, @queries ) {
        print "    Create circos.conf for $id\n";
        $tt->process(
            \$text,
            {   stopwatch   => $stopwatch,
                parallel    => $parallel,
                working_dir => $working_dir,
                name_str    => $name_str,
                id          => $id,
            },
            path( $working_dir, 'Processing', "${id}", "circos.conf" )
                ->stringify
        ) or die Template->error;
    }

    # circos_cmd.sh
    $sh_name = "5_circos_cmd.sh";
    print "Create $sh_name\n";
    $text = <<'EOF';
#!/bin/bash
# perl [% stopwatch.cmd_line %]

cd [% working_dir %]

[% FOREACH id IN all_ids -%]
#----------------------------------------------------------#
# [% id %]
#----------------------------------------------------------#

#----------------------------#
# karyotype
#----------------------------#
cd [% working_dir %]/Processing/[% id %]

# generate karyotype files
if [ ! -e [% working_dir %]/Processing/[% id %]/karyotype.[% id %].txt ]
then
    echo "==> Create deafult karyotype"
    perl -anl -e '$i++; print qq{chr - $F[0] $F[0] 0 $F[1] chr$i}' \
        [% working_dir %]/Genomes/[% id %]/chr.sizes \
        > karyotype.[% id %].txt
fi

# spaces among chromosomes
if [ -e [% working_dir %]/Genomes/[% id %]/chr.sizes ]
then
    if [[ $(perl -n -e '$l++; END{print qq{$l\n}}' [% working_dir %]/Genomes/[% id %]/chr.sizes ) > 1 ]]
    then
        echo "==> Multiple chromosomes"
        perl -nlpi -e 's/    default = 0r/    default = 0.005r/;' [% working_dir %]/Processing/[% id %]/circos.conf
        perl -nlpi -e 's/show_label     = no/show_label     = yes/;' [% working_dir %]/Processing/[% id %]/circos.conf
    fi
fi

# chromosome units
if [ -e [% working_dir %]/Genomes/[% id %]/chr.sizes ]
then
    SIZE=$(perl -an -F'\t' -e '$s += $F[1]; END{print qq{$s\n}}' [% working_dir %]/Genomes/[% id %]/chr.sizes )
    echo "==> Genome size ${SIZE}"
    if [ ${SIZE} -ge 1000000000 ]
    then
        echo "* Set chromosome unit to 1 Mbp"
        perl -nlpi -e 's/chromosomes_units = 1000/chromosomes_units = 100000/;' [% working_dir %]/Processing/[% id %]/circos.conf
    elif [ ${SIZE} -ge 100000000 ]
    then
        echo "* Set chromosome unit to 100 kbp"
        perl -nlpi -e 's/chromosomes_units = 1000/chromosomes_units = 100000/;' [% working_dir %]/Processing/[% id %]/circos.conf
    elif [ ${SIZE} -ge 10000000 ]
    then
        echo "* Set chromosome unit to 10 kbp"
        perl -nlpi -e 's/chromosomes_units = 1000/chromosomes_units = 10000/;' [% working_dir %]/Processing/[% id %]/circos.conf
    else
        echo "* Keep chromosome unit as 1 kbp"
    fi
fi

#----------------------------#
# gff to highlight
#----------------------------#
# coding and other features
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $color = q{};
    $F[2] eq q{CDS} and $color = q{chr9};
    $F[2] eq q{ncRNA} and $color = q{dark2-8-qual-1};
    $F[2] eq q{rRNA} and $color = q{dark2-8-qual-2};
    $F[2] eq q{tRNA} and $color = q{dark2-8-qual-3};
    $F[2] eq q{tmRNA} and $color = q{dark2-8-qual-4};
    $color and ($F[4] - $F[3] > 49) and print qq{$F[0] $F[3] $F[4] fill_color=$color};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    > highlight.features.[% id %].txt

# repeats
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $color = q{};
    $F[2] eq q{region} and $F[8] =~ /mobile_element|Transposon/i and $color = q{chr15};
    $F[2] =~ /repeat/ and $F[8] !~ /RNA/ and $color = q{chr15};
    $color and ($F[4] - $F[3] > 49) and print qq{$F[0] $F[3] $F[4] fill_color=$color};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    > highlight.repeats.[% id %].txt

#----------------------------#
# run circos
#----------------------------#
circos -noparanoid -conf circos.conf

[% END -%]

EOF
    $tt->process(
        \$text,
        {   stopwatch   => $stopwatch,
            parallel    => $parallel,
            working_dir => $working_dir,
            name_str    => $name_str,
            all_ids     => [ $target, @queries ],
            data        => \@data,
        },
        path( $working_dir, $sh_name )->stringify
    ) or die Template->error;

    # feature_cmd.sh
    $sh_name = "6_feature_cmd.sh";
    print "Create $sh_name\n";
    $text = <<'EOF';
#!/bin/bash
# perl [% stopwatch.cmd_line %]

cd [% working_dir %]

[% FOREACH id IN all_ids -%]
#----------------------------------------------------------#
# [% id %]
#----------------------------------------------------------#

#----------------------------#
# gff to feature
#----------------------------#
cd [% working_dir %]/Processing/[% id %]

# coding
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $F[2] eq q{CDS} and print qq{$F[0]:$F[3]-$F[4]};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    > feature.coding.[% id %].txt

# repeats
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $F[2] eq q{region} and $F[8] =~ /mobile_element|Transposon/i and print qq{$F[0]:$F[3]-$F[4]};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    > feature.repeats.[% id %].txt
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $F[2] =~ /repeat/ and $F[8] !~ /RNA/ and print qq{$F[0]:$F[3]-$F[4]};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    >> feature.repeats.[% id %].txt

# others
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $F[2] eq q{ncRNA} and print qq{$F[0]:$F[3]-$F[4]};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    > feature.ncRNA.[% id %].txt
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $F[2] eq q{rRNA} and print qq{$F[0]:$F[3]-$F[4]};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    > feature.rRNA.[% id %].txt
perl -anl -e '
    /^#/ and next;
    $F[0] =~ s/\.\d+//;
    $F[2] eq q{tRNA} and print qq{$F[0]:$F[3]-$F[4]};
    ' \
    [% working_dir %]/Genomes/[% id %]/*.gff \
    > feature.tRNA.[% id %].txt

#----------------------------#
# merge txt and stat
#----------------------------#
for ftr in coding repeats ncRNA rRNA tRNA
do
    if [ -s feature.$ftr.[% id %].txt ]
    then
        # there are some data in .txt file
        runlist cover feature.$ftr.[% id %].txt -o feature.$ftr.[% id %].yml;
    else
        # .txt file is empty
        # create empty runlists from chr.sizes
        perl -ane'BEGIN { print qq{---\n} }; print qq{$F[0]: "-"\n}; END {print qq{\n}};' [% working_dir %]/Genomes/[% id %]/chr.sizes > feature.$ftr.[% id %].yml;
    fi;
    runlist stat --size chr.sizes feature.$ftr.[% id %].yml;
done

echo "feature,name,length,size,coverage" > [% working_dir %]/Results/[% id %]/[% id %].feature.csv
for ftr in coding repeats ncRNA rRNA tRNA
do
    FTR=$ftr perl -nl -e '/^name/ and next; print qq{$ENV{FTR},$_};' feature.$ftr.[% id %].yml.csv;
done >> [% working_dir %]/Results/[% id %]/[% id %].feature.csv

for ftr in coding repeats ncRNA rRNA tRNA
do
    runlist compare --op intersect --mk [% id %].cc.runlist.yml feature.$ftr.[% id %].yml -o [% id %].cc.runlist.$ftr.yml
done

for ftr in coding repeats ncRNA rRNA tRNA
do
    runlist stat --mk --size chr.sizes [% id %].cc.runlist.$ftr.yml;
done

echo "feature,copy,name,length,size,coverage" > [% working_dir %]/Results/[% id %]/[% id %].feature.copies.csv
for ftr in coding repeats ncRNA rRNA tRNA
do
    FTR=$ftr perl -nl -e '/^key/ and next; /\,all\,/ or next; print qq{$ENV{FTR},$_};' [% id %].cc.runlist.$ftr.yml.csv;
done >> [% working_dir %]/Results/[% id %]/[% id %].feature.copies.csv

for ftr in coding repeats ncRNA rRNA tRNA
do
    rm feature.$ftr.[% id %].txt;
    rm feature.$ftr.[% id %].yml;
    rm feature.$ftr.[% id %].yml.csv;
    rm [% id %].cc.runlist.$ftr.yml;
    rm [% id %].cc.runlist.$ftr.yml.csv;
done

[% END -%]

EOF
    $tt->process(
        \$text,
        {   stopwatch   => $stopwatch,
            parallel    => $parallel,
            working_dir => $working_dir,
            egaz        => $egaz,
            name_str    => $name_str,
            all_ids     => [ $target, @queries ],
            data        => \@data,
        },
        path( $working_dir, $sh_name )->stringify
    ) or die Template->error;

    if ( !$nostat ) {
        $sh_name = "7_pair_stat.sh";
        print "Create $sh_name\n";
        $text = <<'EOF';
#!/bin/bash
# perl [% stopwatch.cmd_line %]

cd [% working_dir %]

[% FOREACH id IN all_ids -%]
#----------------------------------------------------------#
# [% id %]
#----------------------------------------------------------#
# gen_alignDB
perl [% aligndb %]/util/multi_way_batch.pl \
    -d [% id %]vs[% id %] \
    -da [% working_dir %]/Results/[% id %] \
    -chr [% working_dir %]/chr_length.csv \
    -lt 1000 --parallel [% parallel %] --run 1-5,21,40

[% END -%]

#----------------------------------------------------------#
# [% name_str %]
#----------------------------------------------------------#
# init db
perl [% aligndb %]/util/multi_way_batch.pl \
    -d [% name_str %]_paralog \
    -chr [% working_dir %]/chr_length.csv \
    -r 1

#----------------------------#
# gen_alignDB.pl
#----------------------------#

[% FOREACH id IN all_ids -%]
# [% id %]
# gen_alignDB to existing database
perl [% aligndb %]/util/multi_way_batch.pl \
    -d [% name_str %]_paralog \
    -da [% working_dir %]/Results/[% id %] \
    -lt 1000 --parallel [% parallel %] --run 2

[% END -%]

#----------------------------#
# rest steps
#----------------------------#
perl [% aligndb %]/util/two_way_batch.pl \
    -d [% name_str %]_paralog \
    -lt 1000 --parallel [% parallel %] --batch 5 \
    --run 5,10,21,30-32,40-42,44

EOF
        $tt->process(
            \$text,
            {   stopwatch   => $stopwatch,
                parallel    => $parallel,
                working_dir => $working_dir,
                aligndb     => $aligndb,
                name_str    => $name_str,
                all_ids     => [ $target, @queries ],
                data        => \@data,
            },
            path( $working_dir, $sh_name )->stringify
        ) or die Template->error;
    }

    # pack_it_up.sh
    $sh_name = "9_pack_it_up.sh";
    print "Create $sh_name\n";
    $text = <<'EOF';
#!/bin/bash
# perl [% stopwatch.cmd_line %]

cd [% working_dir %]

sleep 1;

find . -type f \
    | grep -v -E "\.(sh|2bit)$" \
    | grep -v -F "fake_tree.nwk" \
    > file_list.txt

tar -czvf [% name_str %].tar.gz -T file_list.txt

EOF
    $tt->process(
        \$text,
        {   stopwatch   => $stopwatch,
            parallel    => $parallel,
            working_dir => $working_dir,
            name_str    => $name_str,
        },
        path( $working_dir, $sh_name )->stringify
    ) or die Template->error;

    # message
    $stopwatch->block_message("Execute *.sh files in order.");
}

#----------------------------#
# Finish
#----------------------------#
$stopwatch->end_message;
exit;

#----------------------------------------------------------#
# Subroutines
#----------------------------------------------------------#
sub prep_fa {
    my $infile = shift;
    my $dir    = shift;

    my $basename = path($infile)->basename( '.fna', '.fa', '.fas', '.fasta' );
    my $in_fh    = path($infile)->openr;
    my $out_fh   = path( $dir, "$basename.fa" )->openw;
    while (<$in_fh>) {
        if (/>/) {
            print {$out_fh} ">$basename\n";
        }
        else {
            print {$out_fh} $_;
        }
    }
    close $out_fh;
    close $in_fh;

    return $basename;
}

__END__
