#!/usr/bin/env perl

use strict;
use warnings;
use Carp;
use English;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;
use Memoize;
use DBD::SQLite;

use List::Util qw/min max/;

$OUTPUT_AUTOFLUSH = 1;

memoize "mirror";
memoize "phase";
memoize "consistent";
memoize "linked";
memoize "calc_LR";
memoize "separate_intercross";

my $sex = "ABBABABBBBAABBBBBBBAAAAABABAAABBBBABABABBBABBABABBAAAAAABABBAABBAABAB";

# Chroms only used for graphics and output! Patterns are inferred correctly without them
my %chromosomes = (
    "ABBBBBBABABAABAAAABBBBBAABABBABABAABAAABABBBABBABBABBAABBABBAABBAABBB" => "1",
    "ABBBABABBAABBBBBBABBAABBBBBBABBBABBABABAABBAAABBABBABBAAAAAAAABBAABAB" => "2",
    "ABABABAABAABBBBBBABBBAABBBBAABAABAABAABAAAAABAABBAAAAAAAABBBBABBABBBA" => "3",
    "ABBABBBBBABBABAAAAABAABBBBBBAAAAABABBAABABABAABABBAABABBAAABBBAABBABB" => "4",
    "AABABBABBBABABABBBBABBBBBAABBABABAABABBABAAAAABBBAAABBAABBBBABBBBBABA" => "5",
    "AABABBBBBABBAABABAABAABABABAAAAABAAAABAABBBBAABAABBBBAAABABAABAAAABAB" => "6",
    "AABBAABBABBBAAABBBBBBBBABAAABBAAABAAAAAAABBAAABAAAABAABBBBABABABAABBB" => "7",
    "AABBABBAABBBAAABAABABAAAAABBABBAAAABBABAABABABBBAABAABAAABABAAAAAAAAB" => "8",
    "AABBBABBABAABBABBABBBAABABBBABBABAAAAAABABABAAAAABBBBBAABBABBAABABBAA" => "9",
    "BAHHBABHBBBHABBAABBABHBABAABABABAHBABAAAABAABAAAAAAAABHBBHBBHAABHBAAA" => "10",
    "ABAABBBABBAABAABBAAAAAABABBAABAAAAABBAAAAAAABABBABAAABBABAAAABABABBAB" => "11",
    "AAABBAABBBBABBBABABABBABBAAAAABAAABBABAABBBABAABAAABAAABBBBBBAABBBBAA" => "12",
    "ABAABBBBAAAABABAABBBAAAAAABBBBBBBBAAAAABAAABABABBBABABAABAAABBAABBBAA" => "13",
    "AAABAHHBABHBAHHABBHHBBHAAAABBABBAHBBAAHBAAHBAHBBBHBAABHABBHBBBAABHAHB" => "14",
    "ABBBBBABBAAAABBBBBBABBABBBAAABAABBABAAAAAAAABBABAABABBABBAAAAABAABBAA" => "15",
    "ABBAABBABBBABBBBBBAAAABABBAAABBBBAABABAABBAAABAAABBBBBBBBBABBBAAABABB" => "16",
    "ABBBAABAABBABAABABABABBAABAABBABBAABBAAAABAAABBBAAAABAABBBAAABBBAABAB" => "17",
    "ABAAAABAAAABAABAAAAABAABBAABABBAABAABBAABBBAAAABBAABABBBABBABBBAAABBB" => "18",
    "ABBAABBAABBBAABBBBBAAABBBBAABBBAABAABBBABABBAAABAABBAABBAAAAAABBAABAA" => "19",
    "ABBBABAAABBBBABAABBBBAABBABBABBABBABBBBBBBBBAAABBAAAABBBBBBBABBBBAAAA" => "20",
    "ABBABABBBBAABBBBBBBAAAAABABAAABBBBABABABBBABBABABBAAAAAABABBAABBAABAB" => "21",
);

my %args;
$args{input}   = "";
$args{error}   = "";
$args{output}  = "test";
$args{verbose} = "";

my $options_okay = GetOptions(
    'input=s'  => \$args{input},
    'error=s'  => \$args{error},
    'output=s' => \$args{output},
    'verbose'  => \$args{verbose}
);

my $metadata = { verbose => $args{verbose} };

print STDERR "INFER MARKERS\n";
my ( $blocklist, $linkage_groups, $marker_blocks ) = infer_markers( $args{input}, $args{error}, $metadata );

print STDERR "MAKING LINKAGE MAPS\n";
my $genome = make_linkage_maps( $blocklist, $args{output}, $linkage_groups, $marker_blocks );

output_marker_blocks( $genome, $marker_blocks, $args{output} );

print STDERR "Done\n";

exit;

## INFER MARKERS
sub infer_markers {
    my ( $input, $error, $metadata ) = @_;

    print STDERR "Loading blocks...\n";
    my $blocklist = load_blocks( $input, $error, $metadata );

    my $valid_patterns = validate_blocks( $blocklist, $metadata );

    correct_maternal_patterns( $blocklist, $valid_patterns, $metadata );

    fill_valid_patterns( $blocklist, $valid_patterns, $metadata );

    complete_maternal_patterns( $blocklist, $valid_patterns, $metadata );

    #    collapse( $blocklist, $metadata );

    print STDERR "Writing clean blocks...\n";
    output_blocks( $input, $blocklist );

    exit;
    my ( $linkage_groups, $marker_blocks ) = build_linkage_groups( $blocklist, $metadata );

    ( $blocklist, $linkage_groups, $marker_blocks );
}

sub load_blocks {
    my ( $input, $error, $metadata ) = @_;

    my $blocklist = [];
    my $header;
    my $types;

    my %error;
    if ( $error ne '' ) {
        print STDERR "Loading error corrections...\n";
        open my $errorfile, "<", $error or croak "Can't open error file $error! $OS_ERROR\n";
        while ( my $errorline = <$errorfile> ) {
            chomp $errorline;
            my ( $error, $corrected, @other ) = split /\t/, $errorline;

            $error{$error} = $corrected;
        }
        close $errorfile;
    }

    print STDERR "Load blocks from database...\n" if $metadata->{verbose};
    my @inputfiles = split ',', $input;
    for my $inputfile (@inputfiles) {
        my $dbh = DBI->connect( "dbi:SQLite:dbname=$inputfile", "", "" );

        ( $header, $types ) = get_header_types($dbh);

        my $sth = $dbh->prepare("SELECT * FROM blocks ORDER BY scaffold, start");
        my $fileblocklist = $dbh->selectall_arrayref( $sth, { Slice => {} } );
        push @{$blocklist}, @{$fileblocklist};
        $sth->finish;

        $dbh->disconnect;
    }

    print STDERR "Phasing and correcting blocks...\n" if $metadata->{verbose};

    # Make empty pattern by checking first Maternal pattern (could be any pattern)
    my $empty;
    my $samplenum;
    for my $block ( @{$blocklist} ) {
        if ( $block->{Maternal} ne "" ) {
            $samplenum = length $block->{Maternal};
            $empty     = ' ' x $samplenum;
            last;
        }
    }

    for my $block ( @{$blocklist} ) {
        $block->{validity} = 'i  m p  ';
        for my $type ( keys %{$block} ) {
            if ( $block->{$type} eq "" ) {
                $block->{$type} = $empty;
                next;
            }

            if ( defined $error{ $block->{$type} } ) {
                $block->{$type} = $error{ $block->{$type} };
            }

            if ( defined $error{ mirror( $block->{$type} ) } ) {
                $block->{$type} = $error{ mirror( $block->{$type} ) };
            }

            # Phase and record presence of type patterns
            if ( defined $types->{$type} ) {
                $block->{$type} = phase( $block->{$type} );
                my $typekey = substr $type, 0, 1;
                my $lctk = lc $typekey;
                $block->{validity} =~ s/$lctk /$typekey / if $block->{$type} ne $empty;
            }
        }
    }

    $metadata->{header}  = $header;
    $metadata->{samples} = $samplenum;
    $metadata->{types}   = $types;
    $metadata->{empty}   = $empty;

    get_block_stats( "After loading blocks", $blocklist, $metadata );

    $blocklist;
}

sub validate_blocks {
    my ( $blocklist, $metadata ) = @_;

    my $empty = $metadata->{empty};

    my %valid_patterns;
    $valid_patterns{'Maternal'}{$sex}{'Paternal'}      = undef;
    $valid_patterns{'Maternal'}{$sex}{'IntercrossHom'} = undef;

    for my $block ( @{$blocklist} ) {

        infer_intercross( $block, $empty );

        validate_parental( $block, $empty );

        store_valid_patterns( $block, \%valid_patterns );

    }

    get_block_stats( "After validating blocks", $blocklist, $metadata );

    \%valid_patterns;
}

sub infer_intercross {
    my ( $block, $empty ) = @_;

    if ( $block->{'IntercrossHet'} ne $empty ) {
        if ( $block->{'IntercrossHom'} ne $empty ) {
            if ( intercross_in_phase( $block->{'IntercrossHet'}, $block->{'IntercrossHom'} ) ) {
                my $intercross =
                  merge_coupled_intercross( $block->{'IntercrossHet'}, $block->{'IntercrossHom'} );
                if ( $intercross =~ /-/ ) {
                    $block->{'validity'} =~ s/I /Ie/;
                }
                else {
                    $block->{'validity'} =~ s/I /IE/;
                    $block->{'IntercrossHet'} = $empty;
                }
            }
            else {
                my ( $i1, $i2 ) = merge_repulsion_intercross( $block->{'IntercrossHet'}, $block->{'IntercrossHom'} );
                my $iv = $i1 =~ /-/ ? 'Id' : 'ID';
                $block->{'validity'} =~ s/I /$iv/;
            }
        }
        else {
            $block->{'IntercrossHom'} = $block->{'IntercrossHet'};
            $block->{'IntercrossHet'} = $empty;
            $block->{'validity'} =~ s/I /Is/;
        }
    }
    elsif ( $block->{'IntercrossHom'} ne $empty ) {
        $block->{'validity'} =~ s/I /Is/;
    }
    else {
        # No Intercross patterns, do nothing
    }

    return;
}

sub validate_parental {
    my ( $block, $empty ) = @_;

    return if $block->{'Maternal'} eq $empty and $block->{'Paternal'} eq $empty;

    if ( $block->{'validity'} =~ /^I[EDs]/ ) {
        my $intercross = $block->{'IntercrossHom'};
        if ( $block->{'Maternal'} ne $empty and $block->{'Paternal'} ne $empty ) {
            if (    $intercross ne create_intercross( $block->{'Maternal'}, $block->{'Paternal'} )
                and $intercross ne create_intercross( $block->{'Maternal'},           mirror( $block->{'Paternal'} ) )
                and $intercross ne create_intercross( mirror( $block->{'Maternal'} ), $block->{'Paternal'} )
                and $intercross ne create_intercross( mirror( $block->{'Maternal'} ), mirror( $block->{'Paternal'} ) ) )
            {
                $block->{'validity'} =~ s/I(.) /I$1b/;
            }
            else {
                $block->{'validity'} =~ s/I(.) /I$1B/;
            }
        }

        check_parent_consistent( $block, $intercross, 'Maternal' )
          if $block->{'Maternal'} ne $empty;
        check_parent_consistent( $block, $intercross, 'Paternal' )
          if $block->{'Paternal'} ne $empty;

    }
}

sub check_parent_consistent {
    my ( $block, $intercross, $parent ) = @_;
    my $pch = substr $parent, 0, 1;
    if (   consistent( $intercross, $block->{$parent} )
        or consistent( $intercross, mirror( $block->{$parent} ) ) )
    {
        $block->{'validity'} =~ s/$pch /$pch=/;
    }
    else {
        $block->{'validity'} =~ s/$pch /$pch-/;
    }
}

sub store_valid_patterns {
    my ( $block, $valid_patterns ) = @_;
    if ( $block->{'validity'} =~ /I[EDs]BM=P=/ ) {
        $valid_patterns->{'Maternal'}{ $block->{'Maternal'} }{'Paternal'}{ $block->{'Paternal'} }++;
        $valid_patterns->{'Maternal'}{ $block->{'Maternal'} }{'IntercrossHom'}{ $block->{'IntercrossHom'} }++;
        $valid_patterns->{'Paternal'}{ $block->{'Paternal'} }{'Maternal'}{ $block->{'Maternal'} }++;
        $valid_patterns->{'Paternal'}{ $block->{'Paternal'} }{'IntercrossHom'}{ $block->{'IntercrossHom'} }++;
        $valid_patterns->{'IntercrossHom'}{ $block->{'IntercrossHom'} }{'Maternal'}{ $block->{'Maternal'} }++;
        $valid_patterns->{'IntercrossHom'}{ $block->{'IntercrossHom'} }{'Paternal'}{ $block->{'Paternal'} }++;
        $block->{'validity'} =~ s/[EDs=]/V/g;
        $block->{'validity'} =~ s/I../   /;
        $block->{'validity'} =~ s/ $/V/;
    }
}

sub correct_maternal_patterns {
    my ( $blocklist, $valid_patterns, $metadata ) = @_;

    my $empty = $metadata->{empty};
    my @maternal =
      sort {
        keys %{ $valid_patterns->{'Maternal'}{$b}{'Paternal'} } <=>
          keys %{ $valid_patterns->{'Maternal'}{$a}{'Paternal'} }
      }
      keys %{ $valid_patterns->{'Maternal'} };

    my %merge;
    my %delete;
    for my $i ( 0 .. $#maternal ) {
        my $mi = $maternal[$i];
        next if !defined $valid_patterns->{'Maternal'}{$mi};
        for my $j ( $i + 1 .. $#maternal ) {
            my $mj = $maternal[$j];
            next if !defined $valid_patterns->{'Maternal'}{$mj};
            if ( linked( $mi, $mj ) ) {
                $merge{$mj} = $mi;
                for my $type ( 'Paternal', 'IntercrossHom' ) {
                    for my $pattern ( keys %{ $valid_patterns->{'Maternal'}{$mj}{$type} } ) {

                        # If this pattern only occurs at the erroneous Maternal print, delete it
                        if ( keys %{ $valid_patterns->{$type}{$pattern}{'Maternal'} } == 1 ) {
                            $delete{$pattern}++;
                            for my $type2 ( 'Paternal', 'IntercrossHom' ) {
                                next if $type eq $type2;
                                for my $pattern2 ( keys %{ $valid_patterns->{$type}{$pattern}{$type2} } ) {
                                    delete $valid_patterns->{$type2}{$pattern2}{$type}{$pattern};
                                }
                            }
                            delete $valid_patterns->{$type}{$pattern};
                        }
                        else {
                            # If the pattern occurs at a real print too, replace the wrong Maternal print
                            # with the real print
                            delete $valid_patterns->{$type}{$pattern}{'Maternal'}{$mj};
                            $valid_patterns->{'Maternal'}{$mi}{$type}{$pattern}++;
                            $valid_patterns->{$type}{$pattern}{'Maternal'}{$mi}++;
                        }
                    }
                }
                delete $valid_patterns->{'Maternal'}{$mj};
            }
        }
    }

    for my $block ( @{$blocklist} ) {
        next if $block->{'Maternal'} eq $empty;

        if ( defined $delete{ $block->{'IntercrossHom'} } ) {
            $block->{'IntercrossHom'} = $empty;
            $block->{'validity'} =~ s/I../i  /;
        }
        elsif ( defined $delete{ $block->{'Paternal'} } ) {
            $block->{'Paternal'} = $empty;
            $block->{'validity'} =~ s/P./p /;
        }

        if ( defined $valid_patterns->{'Maternal'}{ $block->{'Maternal'} } ) {
            $block->{'validity'} =~ s/M./MV/;
        }
        elsif ( defined $merge{ $block->{'Maternal'} } ) {
            $block->{'Maternal'} = $merge{ $block->{'Maternal'} };
            $block->{'validity'} =~ s/M./MV/;
        }
        else {
            # If a maternal pattern in a non-valid block contains an error, find the real maternal pattern
            for my $valid_maternal ( keys %{ $valid_patterns->{'Maternal'} } ) {
                if ( linked( $valid_maternal, $block->{'Maternal'} ) ) {
                    $block->{'Maternal'} = $valid_maternal;
                    $block->{'validity'} =~ s/M./MV/;
                    last;
                }
            }
        }
    }
    get_block_stats( "After correcting maternal patterns", $blocklist, $metadata );
    return;
}

sub fill_valid_patterns {
    my ( $blocklist, $valid_patterns, $metadata ) = @_;

    my $empty = $metadata->{empty};
    my $block_count;
    print STDERR "Blocks to process:";
    print STDERR scalar @{$blocklist};
    print STDERR "\n";
    for my $block ( @{$blocklist} ) {
        $block_count++;
        print STDERR "."              if ( $block_count % 1000 == 0 );
        print STDERR "$block_count\n" if ( $block_count % 10000 == 0 );
        next                          if $block->{'validity'} =~ /V$/;    # Skip already valid blocks
        next
          if $block->{'IntercrossHom'} eq $empty
          and $block->{'Paternal'} eq $empty;                             # Cannot fill from Maternal alone

        fill_parents_from_intercross( $block, $valid_patterns, $empty );

        check_existing_valid_patterns( $block, $valid_patterns, $empty );

    }
    print STDERR "\n";
    get_block_stats( "After filling valid patterns", $blocklist, $metadata );
}

sub fill_parents_from_intercross {
    my ( $block, $valid_patterns, $empty ) = @_;

    return if $block->{'IntercrossHom'} eq $empty or $block->{'Maternal'} ne $empty;

    my $intercross = match_maternal_candidates_to_intercross( $block, $valid_patterns, $empty );

    return if $intercross eq '';

    # Fill empty Paternal pattern given Maternal pattern and Intercross pattern
    if ( $block->{'Maternal'} ne $empty and $block->{'Paternal'} eq $empty ) {
        my $paternal_candidate = separate_intercross( $block->{'Maternal'}, $block->{$intercross} );
        $block->{'Paternal'} = $paternal_candidate;
        if ( defined $valid_patterns->{'Paternal'}{$paternal_candidate} ) {
            $block->{'validity'} =~ s/p /PV/;
        }
        else {
            $block->{'validity'} =~ s/p /Pc/;
        }
    }

    return;
}

sub match_maternal_candidates_to_intercross {
    my ( $block, $valid_patterns, $empty ) = @_;

    my @intercross_types =
      $block->{'validity'} =~ /^I[Dde]/ ? ( 'IntercrossHom', 'IntercrossHet' ) : ('IntercrossHom');

    for my $candidate ( keys %{ $valid_patterns->{'Maternal'} } ) {
        for my $intercross_type (@intercross_types) {
            next if $block->{$intercross_type} eq $empty;

            my $status = '';

            if (   consistent( $candidate, $block->{$intercross_type} )
                or consistent( mirror($candidate), $block->{$intercross_type} ) )
            {
                $status = 'c';
            }
            elsif (linked( $candidate, $block->{$intercross_type} )
                or linked( mirror($candidate), $block->{$intercross_type} ) )
            {
                $status = 'l';
            }

            next if $status eq '';

            $block->{'Maternal'} = $candidate;
            $block->{'validity'} =~ s/M./MV/i;
            $block->{'validity'} =~ s/I(.)./I$1$status/;

            return $intercross_type;

        }
    }
    return '';
}

sub check_existing_valid_patterns {
    my ( $block, $valid_patterns, $empty ) = @_;

    # Find valid types in this block
    my %valid_types;
    for my $type ( 'IntercrossHom', 'Maternal', 'Paternal' ) {
        if ( defined $valid_patterns->{$type}{ $block->{$type} } ) {
            my $pch = substr $type, 0, 1;
            $block->{'validity'} =~ s/${pch}./${pch}V/;
            $valid_types{$type}++;
        }
    }

    # Check valid patterns are consistent with each other
    for my $i ( keys %valid_types ) {
        for my $j ( keys %valid_types ) {
            next if $i eq $j;
            if (   !defined $valid_patterns->{$i}{ $block->{$i} }{$j}{ $block->{$j} }
                or !defined $valid_patterns->{$j}{ $block->{$j} }{$i}{ $block->{$i} } )
            {
                map { my $pch = substr $_, 0, 1; $block->{'validity'} =~ s/${pch}V/${pch}X/; } ( $i, $j );
            }
        }
    }
    return if $block->{'validity'} =~ /X/;

    # Fill empty Paternal and Intercross patterns with matching valid patterns
    for my $valid_type ( keys %valid_types ) {
        next if $valid_type eq 'Maternal';
        for my $type ( 'Maternal', 'Paternal', 'IntercrossHom' ) {
            next if $type eq $valid_type;

            my $pch = substr $type, 0, 1;
            next if $block->{validity} =~ /${pch}V/;
            $block->{$type} =
              ( keys %{ $valid_patterns->{$valid_type}{ $block->{$valid_type} }{$type} } )[0];
            $block->{'validity'} =~ s/${pch}./${pch}V/i;
        }
    }

    $block->{'validity'} = "   MVPVV" if $block->{'validity'} =~ /MVPV/;

    return 0;
}

sub complete_maternal_patterns {
    my ( $blocklist, $valid_patterns, $metadata ) = @_;

    infer_intercross_maternal( $blocklist, $valid_patterns );
    fill_remaining_maternal_patterns( $blocklist, $valid_patterns, $metadata );
}

sub infer_intercross_maternal {
    my ( $blocklist, $valid_patterns ) = @_;

    my %maternal_candidates;
    my %intercross_blocks;
    for my $b ( 0 .. $#{$blocklist} ) {
        my $block = $blocklist->[$b];
        if ( $block->{'validity'} =~ /IE m p / ) {
            push @{ $maternal_candidates{ $block->{'IntercrossHom'} }{patterns} }, $block->{'IntercrossHom'};
            $maternal_candidates{ $block->{'IntercrossHom'} }{length} += $block->{'length'};
            push @{ $intercross_blocks{ $block->{'IntercrossHom'} } }, $b;
        }
    }

    my $merged = merge_maternal_candidates( \%maternal_candidates );

    # Update maternal patterns for inferred intercross chromosomes
    for my $m ( keys %{$merged} ) {
        $valid_patterns->{'Maternal'}{$m}{'Paternal'}      = undef;
        $valid_patterns->{'Maternal'}{$m}{'IntercrossHom'} = undef;

        for my $i ( @{ $merged->{$m}{patterns} } ) {
            my $pattern = $i->{original};
            for my $b ( @{ $intercross_blocks{$pattern} } ) {
                $blocklist->[$b]{'Maternal'} = $m;
                $blocklist->[$b]{'Paternal'} = separate_intercross( $m, $pattern );
                $blocklist->[$b]{'validity'} =~ s/I(.).M.P./I$1cMVPc/i;
            }
        }
    }

    get_block_stats( "After inferring intercross maternals", $blocklist, $metadata );

    return;
}

sub merge_maternal_candidates {
    my ($candidates) = @_;

    my @candidates = sort { $candidates->{$b}{length} <=> $candidates->{$a}{length} }
      keys %{$candidates};

    my $longest_candidate = shift @candidates;
    my %merged            = (
        $longest_candidate => {
            patterns => [
                {
                    pattern  => $longest_candidate,
                    original => $longest_candidate,
                    length   => $candidates->{$longest_candidate}{length}
                }
            ],
            length => $candidates->{$longest_candidate}{length}
        }
    );

    for my $c (@candidates) {
        my $patterns = @{ $candidates->{$c}{patterns} };

        my $update_pattern = $c;
        my $out_c          = $c;

        my @merged = sort { $merged{$b}{length} <=> $merged{$a}{length} } keys %merged;
        for my $m (@merged) {
            my $new_pattern = "";
            if ( int_hamming( $c, $m ) <= 6 ) {
                $new_pattern =
                  get_intercross_consensus( $c, $candidates->{$c}{length}, $merged{$m}{patterns} );
            }

            if ( int_hamming( mirror($c), $m ) <= 6 ) {
                $new_pattern = get_intercross_consensus( mirror($c), $candidates->{$c}{length}, $merged{$m}{patterns} );
                $out_c = mirror($c);
            }

            # Update merged pattern
            if ( $new_pattern ne "" ) {
                $update_pattern = $new_pattern;
                if ( $m ne $update_pattern ) {
                    push @{ $merged{$update_pattern}{patterns} }, @{ $merged{$m}{patterns} };
                    $merged{$update_pattern}{length} +=
                      $merged{$m}{length};
                    delete $merged{$m};
                }
                last;
            }
        }

        # Add candidate to merged patterns
        push @{ $merged{$update_pattern}{patterns} },
          { original => $c, pattern => $out_c, length => $candidates->{$c}{length} };
        $merged{$update_pattern}{length} += $candidates->{$c}{length};
        $patterns = @{ $merged{$update_pattern}{patterns} };
    }
    \%merged;
}

sub get_intercross_consensus {
    my ( $c, $c_length, $merged ) = @_;
    my $cM = { pattern => $c, length => $c_length };
    my @consensus_calls;

    for my $m ( $cM, @{$merged} ) {
        my @m = split //, $m->{pattern};
        for my $i ( 0 .. $#m ) {
            $consensus_calls[$i]{ $m[$i] } += $m->{length};
        }
    }

    my $consensus = "";
    for my $con (@consensus_calls) {
        if ( keys %{$con} == 1 ) {
            $consensus .= ( keys %{$con} )[0];
        }
        else {
            map { $con->{$_} = 0 if !defined $con->{$_} } ( 'A', 'B', 'H' );
            my $max = ( $con->{'A'} > $con->{'B'} ) ? 'A' : 'B';
            $consensus .= ( $con->{$max} > ( $con->{'H'} * 0.1 ) ) ? $max : 'H';
        }
    }
    $consensus;
}

sub fill_remaining_maternal_patterns {
    my ( $blocklist, $valid_patterns, $metadata ) = @_;

    my ( $paternal, $orphans ) = assign_remaining_maternal_to_intercross( $blocklist, $valid_patterns );

    assign_orphans( $paternal, $orphans, $blocklist );

    get_block_stats( "After filling remaining maternals", $blocklist, $metadata );
}

sub assign_remaining_maternal_to_intercross {
    my ( $blocklist, $valid_patterns ) = @_;

    my %paternal;
    my %orphans;
    for my $b ( 0 .. $#{$blocklist} ) {
        my $block = $blocklist->[$b];
        my $new_print;
        if ( $block->{'validity'} =~ /I.l/ ) {
            for my $print ( keys %{ $valid_patterns->{'Maternal'} } ) {
                $new_print = $print
                  if consistent( $print,         $block->{'IntercrossHom'} )
                  or consistent( mirror($print), $block->{'IntercrossHom'} );
            }
        }
        if ( $block->{'validity'} =~ /I. m p / ) {
            my $max_lod = 0;
            for my $print ( keys %{ $valid_patterns->{'Maternal'} } ) {
                $new_print = $print
                  if consistent( $print,         $block->{'IntercrossHom'} )
                  or consistent( mirror($print), $block->{'IntercrossHom'} );
                last if defined $new_print;

                my $lod = linked( $print, $block->{'IntercrossHom'} )
                  or linked( mirror($print), $block->{'IntercrossHom'} );
                if ( $lod > $max_lod ) {
                    $max_lod   = $lod;
                    $new_print = $print;
                }
            }
        }
        if ( defined $new_print ) {
            $block->{'Maternal'} = $new_print;
            $block->{'Paternal'} = separate_intercross( $new_print, $block->{'IntercrossHom'} );
            $block->{'validity'} =~ s/I(.)(.+)/I$1cMVPc /;
        }

        if ( $block->{'validity'} =~ /MVP[Vc ]/ ) {
            $paternal{ $block->{'Paternal'} }{ $block->{'Maternal'} } += $block->{'length'};
        }

        if ( $block->{'validity'} =~ /m P/ ) {
            if (   defined $paternal{ $block->{'Paternal'} }
                or defined $paternal{ mirror( $block->{'Paternal'} ) } )
            {
                $block->{'Maternal'} =
                  defined $paternal{ $block->{'Paternal'} }
                  ? ( keys %{ $paternal{ $block->{'Paternal'} } } )[0]
                  : ( keys %{ $paternal{ mirror( $block->{'Paternal'} ) } } )[0];
                $block->{'validity'} =~ s/m P./MVPc/i;
            }
            else {
                $orphans{ $block->{'Paternal'} }{length} += $block->{'length'};
                push @{ $orphans{ $block->{'Paternal'} }{blocks} }, $b;
            }
        }
    }

    ( \%paternal, \%orphans );
}

sub assign_orphans {
    my ( $paternal, $orphans, $blocklist ) = @_;
    print "Paternal only patterns to assign: " . scalar keys( %{$orphans} ) . "\n";
    my $count = 0;
    for my $orphan ( sort { $orphans->{$b}{length} <=> $orphans->{$a}{length} } keys %{$orphans} ) {
        $count++;
        print "."        if $count % 10 == 0;
        print "$count\n" if $count % 100 == 0;

        my %maternal_candidates;
        if (   defined $paternal->{$orphan}
            or defined $paternal->{ mirror($orphan) } )
        {
            my $maternal =
              defined $paternal->{$orphan}
              ? ( keys %{ $paternal->{$orphan} } )[0]
              : ( keys %{ $paternal->{ mirror($orphan) } } )[0];
            $maternal_candidates{$maternal}++;
        }
        else {
            for my $paternal_candidate ( keys %{$paternal} ) {
                next if $paternal_candidate eq $orphan;
                my $lod = linked( $paternal_candidate, $orphan );
                if ( $lod == 0 ) {
                    $lod = linked( mirror($paternal_candidate), $orphan );
                    $paternal_candidate = mirror($paternal_candidate) if $lod > 0;
                }
                next if $lod == 0;
                for my $maternal ( keys %{ $paternal->{$paternal_candidate} } ) {
                    $maternal_candidates{$maternal} += $lod;
                }
            }
        }
        next if keys %maternal_candidates == 0;
        my $maternal = ( sort { $maternal_candidates{$b} <=> $maternal_candidates{$a} } keys %maternal_candidates )[0];
        $paternal->{$orphan}{$maternal} += $orphans->{$orphan}{length};
        for my $b ( @{ $orphans->{$orphan}{blocks} } ) {
            my $block = $blocklist->[$b];
            $block->{'Maternal'} = $maternal;
            $block->{'validity'} =~ s/m P./MVPc/i;
        }
    }
}

sub collapse {
    my ( $blocklist, $metadata ) = @_;
    my $i = 0;
    my $j = 1;
    while ( $j <= $#{$blocklist} ) {
        my $same = 1;
        $same = 0
          if ( $blocklist->[$i]{'scaffold'} ne $blocklist->[$j]{'scaffold'} );
        map {
            if ( $blocklist->[$i]{$_} ne $blocklist->[$j]{$_} ) {
                my $phase_j = phase( $blocklist->[$j]{$_} );
                if ( $blocklist->[$i]{$_} eq $phase_j ) {
                    $blocklist->[$j]{$_} = $phase_j;
                }
                else {
                    $same = 0;
                }
            }
        } keys %{ $metadata->{types} };

        if ($same) {
            $blocklist->[$i]{'end'}    = $blocklist->[$j]{'end'};
            $blocklist->[$i]{'length'} = $blocklist->[$i]{'length'} + $blocklist->[$j]{'length'};
            splice( @{$blocklist}, $j, 1 );
        }
        else {
            $i = $j;
            $j++;
        }
    }

    update_block_stats( "After collapse", $blocklist, $metadata );

    return;
}

sub build_linkage_groups {
    my ( $blocklist, $metadata ) = @_;

    my %linkage_groups;
    my %marker_blocks;

    for my $block ( @{$blocklist} ) {

        #        next if $block->{'validity'} !~ /V$/;
        next if $block->{validity} !~ /MVP[Vc]/;
        my $maternal = $block->{Maternal};
        my $paternal = $block->{Paternal};

        next if ( $maternal eq $metadata->{empty} or $paternal eq $metadata->{empty} );

        $linkage_groups{$maternal}{$paternal}{length} += $block->{length};
        $linkage_groups{$maternal}{$paternal}{blocks}++;
        $linkage_groups{$maternal}{$paternal}{lookup} = $paternal;
        $marker_blocks{$paternal}{ $block->{scaffold} }{ $block->{start} } =
          $block->{end};
    }

    ( \%linkage_groups, \%marker_blocks );
}

sub int_hamming {

    # Calculate hamming distance between intercross and paternal pattern
    my ( $int, $pat ) = @_;
    my $hamming = 0;
    my @i       = split //, $int;
    my @p       = split //, $pat;
    for my $b ( 0 .. $#i ) {
        next if $i[$b] eq 'H' or $i[$b] eq '-' or $p[$b] eq 'H' or $p[$b] eq '-';
        $hamming++ if $i[$b] ne $p[$b];
    }

    $hamming;
}

sub int_match {

    # Check for complete match between intercross and other pattern,
    # ignoring missing bases in intercross pattern
    my ( $intercross, $pattern ) = @_;
    my @i = split //, $intercross;
    my @p = split //, $pattern;
    my $match = 1;
    for my $a ( 0 .. $#i ) {
        next if $i[$a] =~ /[H\-]/ or $p[$a] =~ /[H\-]/;
        if ( $i[$a] ne $p[$a] ) { $match = 0; last; }
    }

    $match;
}

sub output_blocks {
    my $input     = shift;
    my $blocklist = shift;

    my $inputfile = ( split ',', $input )[0];
    my $dbh = DBI->connect( "dbi:SQLite:dbname=$inputfile", "", "", { AutoCommit => 0 } );

    my $sth = $dbh->prepare("DROP TABLE IF EXISTS cleanblocks");
    $sth->execute;
    $dbh->commit;

    my ( $header, $types ) = get_header_types($dbh);
    splice @{$header}, 4, 0, 'validity';
    my $columns = $#{$header};
    my $statement =
      "CREATE TABLE cleanblocks (scaffold text, start integer, end integer, length integer, validity text";
    map { $statement .= ", \"$_\" text" } @{$header}[ 5 .. $columns ];
    $statement .= ")";
    $sth = $dbh->prepare($statement);
    $sth->execute;
    $dbh->commit;

    $statement = "INSERT INTO cleanblocks VALUES (?,?,?,?,?";
    map { $statement .= ",?" } @{$header}[ 5 .. $columns ];
    $statement .= ")";
    my $insert_handle = $dbh->prepare_cached($statement);

    for my $block ( @{$blocklist} ) {
        my @values = map { $block->{$_} } @{$header};
        $insert_handle->execute(@values);
    }
    $dbh->commit;
    $dbh->disconnect;

    return;
}

## MAKE LINKAGE MAPS

sub make_linkage_maps {
    my ( $blocklist, $output, $linkage_groups, $marker_block ) = @_;

    my %genome;

    for my $chromosome_print ( keys %{$linkage_groups} ) {
        my $chromosome = $chromosomes{$chromosome_print} // '-';

        printf STDERR
          "Building map for print $chromosome_print chromosome %3s with %4d paternal markers",
          $chromosome, scalar keys %{ $linkage_groups->{$chromosome_print} };

        clean_print( $linkage_groups, $chromosome_print );
        if ( !defined $linkage_groups->{$chromosome_print} ) {
            print STDERR "\tReject\n";
            next;
        }

        $genome{$chromosome_print} =
          make_linkage_map( $chromosome_print, $linkage_groups->{$chromosome_print}, $output );

    }

    \%genome;
}

sub clean_print {
    my ( $linkage_groups, $chromosome_print ) = @_;

    # Delete paternal patterns less than 1kb long or occurring in only 1 or 2 blocks
    for my $marker ( keys %{ $linkage_groups->{$chromosome_print} } ) {
        $linkage_groups->{$chromosome_print}{$marker}{output} = $marker;

        #        delete $linkage_groups->{$chromosome_print}{$marker}
        #          if (  $linkage_groups->{$chromosome_print}{$marker}{length} < 1000
        #            and $linkage_groups->{$chromosome_print}{$marker}{blocks} <= 2 );
    }

    if ( keys %{ $linkage_groups->{$chromosome_print} } == 0 ) {
        delete $linkage_groups->{$chromosome_print};
    }
}

sub make_linkage_map {
    my ( $chromosome_print, $markers, $output ) = @_;

    # Make map for this maternal pattern
    my $marker_id = run_mstmap( $chromosome_print, $markers, $output );

    my $map = load_map( $output, $chromosome_print );
    my $chromosome_lgs = keys %{$map};
    print STDERR "\tBuilt $chromosome_lgs linkage groups";

    # If more than one linkage map returned for this chromosome,
    # attempt to rephase markers and remake the map
    my $phased_markers;
    if ( $chromosome_lgs == 2 ) {
        phase_linkage_groups( $map, $markers, $marker_id );
        $marker_id = run_mstmap( $chromosome_print, $markers, $output );
        $map = load_map( $output, $chromosome_print );
        my $chromosome_lgs = keys %{$map};
        print STDERR "\tAfter phasing, $chromosome_lgs linkage groups";
    }

    #    smooth_markers( $map, $markers, $marker_id );
    #    $marker_id = run_mstmap( $chromosome_print, $markers, $output );
    #    $map = load_map( $output, $chromosome_print );

    my $map_markers = write_map_markers( $map, $markers, $marker_id, $output, $chromosome_print );
    print STDERR "\n";

    $map_markers;
}

sub run_mstmap {

    my ( $chromosome_print, $markers, $output ) = @_;

    my $mstmap_input = write_mstmap_header( $output, $chromosome_print, $markers );

    my $id = 1;
    my %marker_id;
    for my $marker ( keys %{$markers} ) {
        $marker_id{$id} = $marker;
        $markers->{$marker}{output} = check_mirror( $markers->{$marker}{output}, $markers );
        $id = write_marker( $id, $markers->{$marker}, $mstmap_input );
    }

    close $mstmap_input;

    system(
"MSTMap.exe $output.$chromosome_print.mstmap.input $output.$chromosome_print.mstmap.map > $output.$chromosome_print.mstmap.log"
    );

    \%marker_id;
}

sub write_mstmap_header {
    my ( $output, $chromosome_print, $markers ) = @_;

    my %mst_header = (
        population_type              => "RIL2",
        population_name              => "HeliconiusWGS",
        distance_function            => "kosambi",
        cut_off_p_value              => "0.000001",
        no_map_dist                  => "15",
        no_map_size                  => "2",
        missing_threshold            => "0.75",
        estimation_before_clustering => "yes",
        detect_bad_data              => "yes",
        objective_function           => "ML",
    );

    my @mst_header = (
        "population_type", "population_name",    "distance_function", "cut_off_p_value",
        "no_map_dist",     "no_map_size",        "missing_threshold", "estimation_before_clustering",
        "detect_bad_data", "objective_function", "number_of_loci",    "number_of_individual",
    );

    open my $mstmap_input, ">", "$output.$chromosome_print.mstmap.input"
      or croak "Can't open $output.$chromosome_print.mstmap.input: $OS_ERROR\n";

    my $samples = split //, ( keys %{$markers} )[0];
    $mst_header{"number_of_loci"}       = keys %{$markers};
    $mst_header{"number_of_individual"} = $samples;
    map { print $mstmap_input "$_ $mst_header{$_}\n"; } @mst_header;

    print $mstmap_input "locus_name";
    map { print $mstmap_input "\t$_" } ( 1 .. $samples );
    print $mstmap_input "\n";

    $mstmap_input;
}

sub write_marker {
    my ( $id, $marker, $mstmap_input, $marker_lookup ) = @_;

    print $mstmap_input "$id";
    my @gt = split //, $marker->{output};
    map { print $mstmap_input "\t"; print $mstmap_input $_ eq 'H' ? 'X' : $_; } @gt;
    print $mstmap_input "\n";
    $id++;

    $id;
}

sub load_map {
    my ( $output, $chromosome_print ) = @_;

    open my $mstmap_output, '<', "$output.$chromosome_print.mstmap.map"
      or croak "Can't open map for $chromosome_print! $OS_ERROR\n";

    my %lg;
    my $lg_num;
    my $in_group = 0;
    while ( my $mst_line = <$mstmap_output> ) {
        chomp $mst_line;

        $lg_num = $1 if ( $mst_line =~ /^group (.+)$/ );
        if ( $mst_line eq ";BEGINOFGROUP" ) {
            $in_group = 1;
            next;
        }
        $in_group = 0 if ( $mst_line eq ";ENDOFGROUP" );
        if ($in_group) {
            if ( $mst_line =~ /^(.+)\t([\d\.]+)$/ ) {
                my $id = $1;
                my $cM = $2;
                $lg{$lg_num}{$cM}{$id}++;
            }
        }
    }

    # Delete linkage groups with a single marker
    map { delete $lg{$_} if keys %{ $lg{$_} } == 1 } keys %lg;
    close $mstmap_output;

    \%lg;
}

sub check_mirror {
    my ( $marker, $markers ) = @_;
    my $mirror     = mirror($marker);
    my @markerlist = map { $markers->{$_}{output} } keys %{$markers};
    my $markerh    = sum_hamming( $marker, \@markerlist );
    my $mirrorh    = sum_hamming( $mirror, \@markerlist );

    $markerh < $mirrorh ? $marker : $mirror;
}

sub sum_hamming {
    my ( $marker, $list ) = @_;
    my $h = 0;
    for my $l ( @{$list} ) {
        next if $l eq $marker;
        $h += hamming( $l, $marker );
    }

    $h;
}

sub phase_linkage_groups {
    my ( $map, $markers, $marker_id ) = @_;

    my $first_lg = ( keys %{$map} )[0];
    for my $lg ( keys %{$map} ) {
        for my $cM ( keys %{ $map->{$lg} } ) {
            for my $id ( keys %{ $map->{$lg}{$cM} } ) {
                my $marker = $marker_id->{$id};
                my $output = $markers->{$marker}{output};
                my $phased = $lg eq $first_lg ? mirror($output) : $output;
                $markers->{$marker}{output} = $phased;
            }
        }
    }
}

sub smooth_markers {
    my ( $map, $markers, $marker_id ) = @_;

    my @markerlist;
    for my $lg ( sort keys %{$map} ) {
        for my $cM ( sort { $a <=> $b } keys %{ $map->{$lg} } ) {
            for my $id ( sort { $a <=> $b } keys %{ $map->{$lg}{$cM} } ) {
                push @markerlist,
                  {
                    pattern  => $markers->{ $marker_id->{$id} }{output},
                    original => $marker_id->{$id}
                  };
            }
        }
    }

    my %output;
    my $samples;
    for my $mref (@markerlist) {
        $samples = length $mref->{pattern};
        my @out = split //, $mref->{pattern};
        $output{ $mref->{pattern} } = \@out;
    }

    for my $sample ( 0 .. $samples - 1 ) {
        my $haplotype_len = 0;
        my $cur_gt        = '';
        for my $m ( 0 .. $#markerlist ) {
            my $gt = $output{ $markerlist[$m]{pattern} }[$sample];
            if ( $cur_gt ne $gt ) {
                $cur_gt = $gt;
                if ( $haplotype_len <= 3 ) {
                    for my $h ( 1 .. $haplotype_len ) {
                        $output{ $markerlist[ $m - $h ]{pattern} }[$sample] = $cur_gt;
                    }
                }
                $haplotype_len = 1;
            }
            else {
                $haplotype_len++;
            }
        }
    }

    map { $markers->{ $_->{original} }{output} = join '', @{ $output{ $_->{pattern} } }; } @markerlist;
}

sub write_map_markers {
    my ( $map, $markers, $marker_id, $output, $chromosome_print ) = @_;

    my %chromosome;
    open my $map_marker_file, ">", "$output.$chromosome_print.mstmap.markers"
      or croak "Can't open $output.$chromosome_print.mstmap.markers: $OS_ERROR\n";

    print $map_marker_file "ID\tLG\tCM\tOriginal\tOutput\tLength\n";
    for my $lg ( sort keys %{$map} ) {
        for my $cM ( sort { $a <=> $b } keys %{ $map->{$lg} } ) {
            for my $id ( sort { $a <=> $b } keys %{ $map->{$lg}{$cM} } ) {
                my $marker = $marker_id->{$id};
                $chromosome{$lg}{$cM}{$marker}{length} = $markers->{$marker}{length};
                $chromosome{$lg}{$cM}{$marker}{output} = $markers->{$marker}{output};
                print $map_marker_file "$id\t$lg\t$cM";
                print $map_marker_file "\t$marker\t$markers->{$marker}{output}";
                print $map_marker_file "\t$markers->{$marker}{length}";
                print $map_marker_file "\n";
            }
        }
    }
    close $map_marker_file;

    \%chromosome;
}

## MAP GENOME

sub output_marker_blocks {
    my ( $genome, $marker_blocks, $output ) = @_;

    open my $chromosome_map_file, '>', "$output.chromosome.map.tsv"
      or croak "Can't open chromosome map file! $OS_ERROR\n";
    print $chromosome_map_file "Chromosome\tPrint\tcM\tOriginalMarker\tCleanMarker\tLength\n";
    open my $scaffold_map_file, '>', "$output.scaffold.map.tsv"
      or croak "Can't open scaffold map file! $OS_ERROR\n";
    print $scaffold_map_file "Chromosome\tcM\tScaffold\tStart\tEnd\tLength\n";

    my %chromosome_numbers;
    my $new_chromosome_number = 100;
    for my $print ( keys %{$genome} ) {
        my $chromosome = $chromosomes{$print} // $new_chromosome_number;
        $new_chromosome_number++ if $chromosome == $new_chromosome_number;
        $chromosome_numbers{$chromosome} = $print;
    }
    for my $chromosome ( sort { $a <=> $b } keys %chromosome_numbers ) {
        my $chromosome_print = $chromosome_numbers{$chromosome};
        croak "More than one linkage group found for chromosome print $chromosome_print"
          if keys %{ $genome->{$chromosome_print} } > 1;
        for my $lg ( sort keys %{ $genome->{$chromosome_print} } ) {
            for my $cM ( sort { $a <=> $b } keys %{ $genome->{$chromosome_print}{$lg} } ) {
                for my $marker ( keys %{ $genome->{$chromosome_print}{$lg}{$cM} } ) {
                    print $chromosome_map_file "$chromosome\t$chromosome_print\t$cM\t$marker";
                    print $chromosome_map_file "\t$genome->{$chromosome_print}{$lg}{$cM}{$marker}{output}";
                    print $chromosome_map_file "\t$genome->{$chromosome_print}{$lg}{$cM}{$marker}{length}";
                    print $chromosome_map_file "\n";

                    for my $scaffold ( sort keys %{ $marker_blocks->{$marker} } ) {
                        my $block_start = -1;
                        my $last_end    = -1;
                        for my $start (
                            sort { $a <=> $b }
                            keys %{ $marker_blocks->{$marker}{$scaffold} }
                          )
                        {
                            $block_start = $start if $block_start == -1;
                            if ( $last_end != -1 and $start > $last_end + 1 ) {
                                my $length = $last_end - $block_start + 1;
                                print $scaffold_map_file
                                  "$chromosome\t$cM\t$scaffold\t$block_start\t$last_end\t$length\n";
                                $block_start = $start;
                            }
                            $last_end = $marker_blocks->{$marker}{$scaffold}{$start};
                        }
                        my $length = $last_end - $block_start + 1;
                        print $scaffold_map_file "$chromosome\t$cM\t$scaffold\t$block_start\t$last_end\t$length\n";
                    }
                }
            }
        }
    }
    close $chromosome_map_file;
    close $scaffold_map_file;
}

## STATISTICS

sub get_block_stats {
    my ( $step, $blocklist, $metadata ) = @_;

    my $stats = get_stats( $blocklist, $metadata );

    $metadata->{stats} = $stats;
    return if !$metadata->{verbose};

    for my $type ( @{ $metadata->{header} } ) {
        next if !defined $metadata->{types}{$type};
        output_type_stats( $step, $type, $stats ) if $metadata->{verbose};
    }

    return;
}

sub update_block_stats {
    my ( $step, $blocklist, $metadata ) = @_;

    my $stats = get_stats( $blocklist, $metadata );

    my $all_equal = 1;

    for my $type ( @{ $metadata->{header} } ) {
        next if !defined $metadata->{types}{$type};

        next if stats_equal( $metadata->{stats}{$type}, $stats->{$type} );

        $all_equal = 0;

        output_type_stats( $step, $type, $stats ) if $metadata->{verbose};
    }

    if ( $all_equal and $metadata->{verbose} ) {
        printf STDERR "%-60s", $step;
        print STDERR "No change\n";
    }

    $metadata->{stats} = $stats;

    return;
}

sub output_type_stats {
    my ( $step, $type, $stats ) = @_;

    printf STDERR "%-60s", $step;
    printf STDERR "%-25s", $type;
    for my $full ('ok') {
        printf STDERR "%12d", $stats->{$type}{$full}{patterns};
        printf STDERR "%12d", $stats->{$type}{$full}{blocks};
        printf STDERR "%12d", $stats->{$type}{$full}{bases};
    }
    print STDERR "\n";

    return;
}

sub get_stats {
    my ( $blocklist, $metadata ) = @_;

    my %stats;
    my $empty = $metadata->{empty};

    my %validities;
    for my $block ( @{$blocklist} ) {
        for my $type ( sort keys %{ $metadata->{types} } ) {

            next if $block->{$type} eq $empty;

            my $full = $block->{$type} =~ /\-/ ? 'no' : 'ok';

            $stats{$type}{$full}{blocks}++;
            $stats{$type}{$full}{bases} += $block->{'length'};
            $stats{$type}{$full}{patterns}{ $block->{$type} }++;
        }
        $validities{ $block->{validity} }{blocks}++;
        $validities{ $block->{validity} }{bases} += $block->{'length'};
    }
    for my $validity ( sort { $validities{$b}{bases} <=> $validities{$a}{bases} } keys %validities ) {
        printf "%s\t%5d\t%10d\n", $validity, $validities{$validity}{blocks}, $validities{$validity}{bases};
    }
    for my $type ( keys %{ $metadata->{types} } ) {
        for my $full ( 'ok', 'no' ) {
            $stats{$type}{$full}{blocks} = $stats{$type}{$full}{blocks} // 0;
            $stats{$type}{$full}{bases}  = $stats{$type}{$full}{bases}  // 0;
            $stats{$type}{$full}{patterns} =
              defined $stats{$type}{$full}{patterns}
              ? scalar keys %{ $stats{$type}{$full}{patterns} }
              : 0;
        }
    }

    \%stats;
}

sub stats_equal {
    my ( $oldstats, $newstats ) = @_;
    my $stats_equal = 1;

    for my $full ( 'ok', 'no' ) {
        $stats_equal = 0 if $oldstats->{$full}{patterns} ne $newstats->{$full}{patterns};
        $stats_equal = 0 if $oldstats->{$full}{blocks} ne $newstats->{$full}{blocks};
        $stats_equal = 0 if $oldstats->{$full}{bases} ne $newstats->{$full}{bases};
    }

    $stats_equal;
}

## LIBRARY FUNCTIONS

sub create_intercross {
    my ( $maternal, $paternal ) = @_;
    my @m = split //, $maternal;
    my @p = split //, $paternal;

    my @i = map { ( $m[$_] eq $p[$_] ) ? $m[$_] : 'H' } 0 .. $#m;

    join '', @i;
}

sub separate_intercross {
    my ( $pattern, $intercross ) = @_;

    $intercross = mirror($intercross)
      if int_hamming( $pattern, mirror($intercross) ) < int_hamming( $pattern, $intercross );
    my @intercross = split //, $intercross;
    my @pattern    = split //, $pattern;
    my @complement =
      map {
            $pattern[$_] eq 'H'    ? 'H'
          : $intercross[$_] eq '-' ? '-'
          : $intercross[$_] eq 'H' ? ( $pattern[$_] eq 'A' ? 'B' : 'A' )
          : $intercross[$_]
      } 0 .. $#intercross;
    my $complement = join '', @complement;

    $complement;
}

sub intercross_in_phase {
    my ( $i1, $i2 ) = @_;
    my @i1 = split //, $i1;
    my @i2 = split //, $i2;

    my $h_match    = 0;
    my $h_mismatch = 0;
    for my $i ( 0 .. $#i1 ) {
        if ( $i1[$i] eq 'H' ) {
            if ( $i2[$i] eq 'H' ) {
                $h_match++;
            }
            else {
                $h_mismatch++;
            }
        }
    }
    $h_match > $h_mismatch;
}

sub merge_coupled_intercross {
    my ( $i1, $i2 ) = @_;
    my @i1 = split //, $i1;
    my @i2 = split //, $i2;

    my @out;
    for my $i ( 0 .. $#i1 ) {
        $out[$i] = $i1[$i] eq $i2[$i] ? $i1[$i] : '-';
    }
    my $out = join '', @out;

    $out;
}

sub merge_repulsion_intercross {
    my ( $i1, $i2 ) = @_;

    # I1 should be the pattern that starts with A; I2 starts with H
    if ( $i2 =~ /^A/ ) {
        my $t = $i1;
        $i1 = $i2;
        $i2 = $t;
    }

    my @i1 = split //, $i1;
    my @i2 = split //, $i2;

    my @out1;
    my @out2;
    for my $i ( 0 .. $#i1 ) {
        if ( ( $i1[$i] eq 'A' and $i2[$i] eq 'B' ) or ( $i1[$i] eq 'B' and $i2[$i] eq 'A' ) ) {
            $out1[$i] = '-';
            $out2[$i] = '-';
        }
        elsif ( $i1[$i] eq $i2[$i] or $i2[$i] eq 'H' ) {    # A,A; B,B; H,H; A,H; B,H
            $out1[$i] = $i1[$i];
            $out2[$i] = $i1[$i];
        }
        elsif ( $i1[$i] eq 'H' ) {
            $out1[$i] = $i2[$i];
            $out2[$i] = $i2[$i] eq 'A' ? 'B' : 'A';
        }
    }

    my $out1 = join '', @out1;
    my $out2 = join '', @out2;

    ( $out1, $out2 );
}

sub consistent {
    my ( $pattern1, $pattern2 ) = @_;

    my @pattern1 = split //, $pattern1;
    my @pattern2 = split //, $pattern2;
    my $distance = 0;
    for my $i ( 0 .. $#pattern1 ) {
        return 0
          if $pattern1[$i] ne $pattern2[$i]
          and $pattern1[$i] ne 'H'
          and $pattern2[$i] ne 'H';
    }
    return 1;
}

sub phase {
    my $pat = shift;
    my @checkbases;
    if ( $pat =~ 'A' && $pat =~ 'B' && $pat =~ 'H' ) {
        @checkbases = ( 'A', 'B' );
    }
    elsif ( $pat =~ 'A' && $pat =~ 'B' && $pat !~ 'H' ) {
        @checkbases = ( 'A', 'B' );
    }
    elsif ( $pat =~ 'B' && $pat =~ 'H' && $pat !~ 'A' ) {
        @checkbases = ( 'B', 'H' );
    }
    return " " x length($pat) if !@checkbases;

    my @p = split //, $pat;
    my $out = "";
    my %trans;

    for my $gt (@p) {
        my $added = 0;
        for my $bi ( 0, 1 ) {
            if ( $gt eq $checkbases[$bi] ) {
                if ( !defined $trans{$gt} ) {
                    $trans{ $checkbases[$bi] } = 'A';
                    my $other = $bi == 0 ? 1 : 0;
                    $trans{ $checkbases[$other] } = 'B';
                }
                $out .= $trans{$gt};
                $added++;
            }
        }
        $out .= $gt =~ /[ ~\.]/ ? '-' : $gt if !$added;
    }

    $out;
}

sub mirror {
    my $pat = shift;
    if (   ( $pat =~ 'A' and $pat =~ 'B' and $pat =~ 'H' )
        or ( $pat =~ 'A' and $pat =~ 'B' and $pat !~ 'H' ) )
    {
        $pat =~ tr/AB/BA/;
    }
    if ( $pat =~ 'A' and $pat =~ 'H' and $pat !~ 'B' ) {
        $pat =~ tr /AH/HA/;
    }
    if ( $pat =~ 'B' and $pat =~ 'H' and $pat !~ 'A' ) {
        $pat =~ tr /HB/BH/;
    }

    $pat;
}

sub hamming {
    return ( $_[0] ^ $_[1] ) =~ tr/\001-\255//;
}

sub get_header_types {
    my $dbh = shift;

    my $sth = $dbh->prepare("SELECT * FROM blocks WHERE scaffold = 'getcolumnnames'");
    $sth->execute;
    my @header = @{ $sth->{NAME} };

    my %types;
    map { $types{$_} = "" } @header;
    delete $types{"scaffold"};
    delete $types{"start"};
    delete $types{"end"};
    delete $types{"length"};

    ( \@header, \%types );
}

## Linkage tests

sub linked {
    my ( $a, $b, $lod_threshold ) = @_;
    $lod_threshold = 6 if !defined $lod_threshold;
    ( $a =~ /H/ and $b =~ /H/ )
      ? linked_intercross( $a, $b, $lod_threshold )
      : linked_backcross( $a, $b, $lod_threshold );
}

sub linked_backcross {
    my ( $a, $b, $lod_threshold ) = @_;

    # If either pattern is Intercross, remove individuals where Intercross is H
    if ( $a =~ /H/ or $b =~ /H/ ) {
        my @a = split //, $a;
        my @b = split //, $b;
        my @new_a;
        my @new_b;
        for my $i ( 0 .. $#a ) {
            next if $a[$i] =~ /H/ or $b[$i] =~ /H/;
            push @new_a, $a[$i];
            push @new_b, $b[$i];
        }
        $a = join '', @new_a;
        $b = join '', @new_b;
    }
    my $N = length $a;
    my $R = hamming( $a, $b );
    my $r = $R / $N;
    my $LOD =
      ( ( $N - $R ) * ( log( 1 - $r ) / log(10) ) ) + ( $R * ( log($r) / log(10) ) ) + ( $N * ( log(2) / log(10) ) );
    return $LOD > $lod_threshold ? $LOD : 0;
}

sub linked_intercross {
    my ( $a, $b, $lod_threshold ) = @_;

    my $N      = length $a;
    my $haps   = get_haps( $a, $b );
    my $r      = f2_em( $haps, $N, 0.25 );
    my $p_re   = calc_p_re($r);
    my $R      = calc_R( $haps, $p_re );
    my $LR_r   = calc_LR( $r, $R, $N );
    my $LR_ind = calc_LR( 0.5, $R, $N );
    my $LOD    = log( $LR_r / $LR_ind ) / log(10);
    return $LOD > $lod_threshold ? $LOD : 0;
}

sub f2_em {
    my ( $haps, $N, $r ) = @_;
    for my $i ( 1 .. 100 ) {
        my $p_re  = calc_p_re($r);
        my $R     = calc_R( $haps, $p_re );
        my $S     = calc_S( $haps, $p_re );
        my $new_r = $R / ( 2 * $N );
        last if sprintf( "%.5f", $new_r ) eq sprintf( "%.5f", $r );
        $r = $new_r;
    }

    $r;
}

sub get_haps {
    my ( $a, $b ) = @_;

    my @a = split //, $a;
    my @b = split //, $b;

    my %haps;
    for my $i ( 'A', 'B', 'H' ) {
        for my $j ( 'A', 'B', 'H' ) {
            $haps{ $i . $j } = 0;
        }
    }
    for my $i ( 0 .. $#a ) {
        my $hap = $a[$i] . $b[$i];
        $haps{$hap}++;
    }
    return \%haps;
}

sub calc_p_re {
    my $r = shift;
    ( $r**2 ) / ( ( ( 1 - $r )**2 ) + ( $r**2 ) )

}

sub calc_R {
    my ( $haps, $p_re ) = @_;

    0 * $haps->{'AA'} +
      1 * $haps->{'AH'} +
      2 * $haps->{'AB'} +
      1 * $haps->{'HA'} +
      2 * $haps->{'HH'} * $p_re +
      1 * $haps->{'HB'} +
      2 * $haps->{'BA'} +
      1 * $haps->{'BH'} +
      0 * $haps->{'BB'};
}

sub calc_S {
    my ( $haps, $p_re ) = @_;

    2 * $haps->{'AA'} +
      1 * $haps->{'AH'} +
      0 * $haps->{'AB'} +
      1 * $haps->{'HA'} +
      2 * $haps->{'HH'} * ( 1 - $p_re ) +
      1 * $haps->{'HB'} +
      0 * $haps->{'BA'} +
      1 * $haps->{'BH'} +
      2 * $haps->{'BB'};
}

sub calc_LR {
    my ( $r, $R, $N ) = @_;
    ( 1 - $r )**( $N - $R ) * ( $r**$R );
}
