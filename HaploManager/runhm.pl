#!/usr/bin/env perl

# runhm.pl
# Run HaploMerger

# -f FASTA file of genome, zipped or unzipped
# -d Directory containing HaploMerger scripts and config files:
#    - hm.batchA-G
#    - scoreMatrix.q
#    - all_lastz.ctl
# -o Name of output directory
# -p final scaffold prefix

# Process
# 1. Create output directory
# 2. Copy config directory files to output directory
# 3. Copy FASTA file to directory, rename as genome.fa
# 4. Run hm.batchA
# 5. Run hm.batchB
# 6. Run hm.batchC
# 7. Create merged assembly of optimized scaffolds and unpaired scaffolds:
#    - If -p is provided, add prefix to optimized scaffolds
#    - Rename unpaired scaffolds to original names

# John Davey
# johnomics@gmail.com
# Begun Friday 20 March 2015

use strict;
use warnings;
use Carp;
use English;
use Getopt::Long;
use File::Basename 'fileparse';
use File::Copy 'copy';
use File::Copy::Recursive 'dircopy';
use File::Path 'rmtree';
use IO::Uncompress::Gunzip qw($GunzipError);
use Cwd;

# Autoflush output so reporting on progress works
$| = 1;

my $input           = "";
my $configdir       = "";
my $outputdir       = "";
my $prefix          = "";
my $scaffold_prefix = "";
my $g;

my $options_okay = GetOptions(
    'input=s'           => \$input,
    'configdir=s'       => \$configdir,
    'outputdir=s'       => \$outputdir,
    'prefix=s'          => \$prefix,
    'scaffold_prefix=s' => \$scaffold_prefix,
    'g'                 => \$g,
);

croak "No output directory! Please specify -o $OS_ERROR\n" if $outputdir eq "";

if ( !-d $outputdir ) {
    croak "No config directory! Please specify -c $OS_ERROR\n" if $configdir eq "";
    croak "Config directory $configdir does not exist!\n" if !-d $configdir;
    dircopy $configdir, $outputdir;
}

if ( !-e "$outputdir/genome.fa" ) {
    croak "No FASTA file! Please specify -f $OS_ERROR\n" if $input eq "";
    croak "FASTA file $input does not exist!\n" if !-e $input;
    copy $input, "$outputdir/genome.fa";
}

my ( $filename, $dirs, $suffix ) = fileparse( $input, qr/\.[^.]*/ );
chdir $outputdir;

my $log;
if ( !-e "runhm.log" ) {
    open $log, '>', "runhm.log";
}
else {
    open $log, '>>', "runhm.log";
}

print $log "HaploMerger run log\n";
print $log "Genome: $input\n";
print $log "Config directory: $configdir\n";
print $log "Output directory: $outputdir\n";
print $log "Prefix: $prefix\n";

my $start_time = localtime;
my $start      = time;
print $log "Start time: $start_time\n";

my $optimized_file = "optiNewScaffolds.fa.gz";
my $unpaired_file  = "unpaired.fa.gz";

( $optimized_file, $unpaired_file, $log, my $next_start ) = run_abc( $log, $start );

( $optimized_file, $unpaired_file, $log, $next_start ) = run_f( $log, $next_start, $outputdir, $scaffold_prefix )
  if $scaffold_prefix;

output_final_genome( $outputdir, $optimized_file, $unpaired_file, $prefix );

if ($g) {
    ( $optimized_file, $unpaired_file, $log, $next_start ) = run_g( $log, $next_start );
    output_final_genome( $outputdir, $optimized_file, $unpaired_file, $prefix, "refined" );
}

open $log, '>>', "runhm.log";

if ( -d 'genome.genomex.result/raw.axt' ) {
    printf $log "Removing raw.axt folder\n";
    rmtree ['genome.genomex.result/raw.axt'];
}

my $end_time = localtime;
print $log "End time: $end_time\n";

output_duration( "Total", $log, $start );
print $log "Done\n";
close $log;

sub run_abc {
    my ( $log, $start ) = @_;
    my $c_start = $start;
    if ( !-e "genome.genomex.result/mafFiltered.net.maf.tar.gz" ) {
        system "./hm.batchA.initiation_and_all_lastz genome > runhm.out 2>&1";
        my $b_start = output_duration( "A", $log, $start );
        system "./hm.batchB.chainNet_and_netToMaf genome >> runhm.out 2>&1";
        $c_start = output_duration( "B", $log, $b_start );
    }

    my $next_start = $c_start;
    if ( !-e "genome.genomex.result/optiNewScaffolds.fa.gz" ) {
        system "./hm.batchC.haplomerger genome >> runhm.out 2>&1";
        $next_start = output_duration( "C", $log, $c_start );
    }

    ( "optiNewScaffolds.fa.gz", "unpaired.fa.gz", $log, $next_start );
}

sub run_f {
    my ( $log, $start, $outputdir, $scaffold_prefix ) = @_;
    my $next_start = $start;

    edit_new_scaffolds($scaffold_prefix);

    copy "genome.genomex.result/optiNewScaffolds.fa.gz", "genome.genomex.result/optiNewScaffolds_unrefined.fa.gz";

    if ( -e "genome.genomex.result/hm.new_scaffolds_edited" ) {
        system "./hm.batchF.refine_haplomerger_connections_and_Ngap_fillings genome >> runhm.out 2>&1";
        $next_start = output_duration( "F", $log, $next_start );
    }

    ( "optiNewScaffolds.fa.gz", "unpaired.fa.gz", $log, $next_start );
}

sub edit_new_scaffolds {
    my ($scaffold_prefix) = @_;

    open my $new_scaffolds, '<', "genome.genomex.result/hm.new_scaffolds"
      or croak "Can't open new scaffolds file!\n";
    open my $edited, '>', "genome.genomex.result/hm.new_scaffolds_edited"
      or croak "Can't open edited new scaffolds file!\n";

    while ( my $portion = <$new_scaffolds> ) {
        if ( $portion =~ /^#/ or $portion =~ /^$/ ) {
            print $edited $portion;
            next;
        }

        my @f         = split "\t", $portion;
        my $scaffold1 = $f[5];
        my $scaffold2 = $f[12];
        if ($scaffold1 eq '0' or $scaffold2 eq '0') {
            print $edited $portion;
            next;
        };

        my $active_portion = 0;
        if ( $scaffold1 =~ /^$scaffold_prefix/ and $scaffold2 !~ /^$scaffold_prefix/ ) {
            $active_portion = 2;
        }
        elsif ( $scaffold1 !~ /^$scaffold_prefix/ and $scaffold2 =~ /^$scaffold_prefix/ ) {
            $active_portion = 1;
        }

        $f[-2] = $active_portion if $active_portion;

        my $out = join "\t", @f;
        print $edited $out;
    }
    close $new_scaffolds;
    close $edited;
}

sub run_g {
    my ( $log, $start ) = @_;
    my $next_start = $start;

    if ( !-e "genome.genomex.result/unpaired_refined.fa.gz" ) {
        system "./hm.batchG.refine_unpaired_sequences genome >> runhm.out 2>&1";
        $next_start = output_duration( "G", $log, $start );
    }
    ( "optiNewScaffolds.fa.gz", "unpaired_refined.fa.gz", $log, $next_start );
}

sub output_final_genome {
    my ( $outputdir, $optimized_file, $unpaired_file, $prefix, $suffix ) = @_;

    chdir "genome.genomex.result";

    my $outname = $suffix ? "$outputdir\_$suffix" : "$outputdir";

    if ( !-e "$outname.fa" ) {
        open my $finalgenome, '>', "$outname.fa";

        output_optimized_genome( $optimized_file, $finalgenome, $prefix, $outname );

        output_unpaired_genome( $unpaired_file, $finalgenome, $prefix, $outname );

        close $finalgenome;

        system "summarizeAssembly.py $outname.fa > $outname.summary";
    }
    chdir "..";
}

sub output_optimized_genome {
    my ( $optimized_file, $finalgenome, $prefix, $outname ) = @_;

    if ( !-e $optimized_file ) {
        print $log "$optimized_file does not exist, abandon writing to final genome\n";
        return;
    }

    print $log "Writing $optimized_file to $outname.fa\n";
    my $opti = IO::Uncompress::Gunzip->new($optimized_file)
      or die "IO::Uncompress::Gunzip failed to open $optimized_file: $GunzipError\n";

    while ( my $fastaline = <$opti> ) {
        if ( $fastaline =~ /^>(.+) (.+)$/ ) {
            print $finalgenome ">$prefix$1 $2\n";
        }
        else {
            print $finalgenome $fastaline;
        }
    }

    close $opti;

}

sub output_unpaired_genome {
    my ( $unpaired_file, $finalgenome, $prefix, $outname ) = @_;

    if ( !-e $unpaired_file ) {
        print $log "$unpaired_file does not exist, abandon writing to final genome\n";
        return;
    }

    print $log "Writing $unpaired_file to $outname.fa\n";
    my $unpaired = IO::Uncompress::Gunzip->new($unpaired_file)
      or die "IO::Uncompress::Gunzip failed to open $unpaired_file: $GunzipError\n";

    while ( my $fastaline = <$unpaired> ) {
        if ( $fastaline =~ />(.+) old_(.+?);(.+)/ ) {
            print $finalgenome ">$prefix$1 old_$2;$3\n";
        }
        else {
            print $finalgenome $fastaline;
        }
    }

    close $unpaired;

}

sub output_duration {
    my ( $stage, $file, $start ) = @_;
    my $end      = time;
    my $duration = $end - $start;

    printf $file "$stage run time: %02d:%02d:%02d\n", int( $duration / 3600 ), int( ( $duration % 3600 ) / 60 ),
      int( $duration % 60 );

    $end;
}
