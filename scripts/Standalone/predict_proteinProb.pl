#!/usr/bin/env perl
use strict;
use 5.010;
use warnings;

use Getopt::Long;
use File::Basename;
use IPC::Cmd qw[can_run run];
use File::Temp qw/ tempfile tempdir /;
use FindBin qw($Bin);

use Cwd;

#usage information
my $usage = <<USAGE;
Usage: predict_proteinProb.pl -i in.fa  -o outfile
 Options:
  -i        input fasta file, default STDIN. This can be a file with multiple headers. Must be protein.
  -o        output folder
  --verbose print extra output for diagnostic goals
USAGE
# TODO add option to keep intermediate files
my $in_fasta   = '';
my $out_folder = dirname './';
my $verbose = 0;
die $usage
  unless GetOptions(
    "i:s" => \$in_fasta,
    "o:s" => \$out_folder,
    'verbose' => \$verbose,
  );
#Environment checking
can_run('python')   or die 'python is not installed!';
can_run('python')   or die 'python is not installed!';
can_run('bedtools') or die 'bedtools is not installed!';

sub print_if_verbose {
    my ($print_string, $verboseness) = @_;
    if ($verboseness) {
        print "$print_string";
    }
}


my $wordvec_file = $Bin . "/../../datasets/wordvec/uniprot_sprot70_size60.txt";
die "Cannot detect wordvec_file:$wordvec_file" unless -e $wordvec_file;

# TODO What is the purpose of this test file?
my $test_fa_file = $Bin . "/../../datasets/testSun.fasta";
die "Cannot detect testing data set:$test_fa_file" unless -e $test_fa_file;

my $train_wvc = $Bin . "/../../Trained_model/";
die "Cannot detect training data set:$train_wvc" unless -d $train_wvc;

$out_folder =~ s/[\/|\|]+$//;
mkdir $out_folder unless -d $out_folder;

#############################################
#input and output file initiation
#############################################

my $in_fasta_fh;
if ( $in_fasta && $in_fasta ne '-' ) {
    die "input fastafile does not exists\n" unless -e $in_fasta;
    open $in_fasta_fh, "<", $in_fasta or die "cannot open file $in_fasta:$!\n";
}
else {
    if (@ARGV) {
        if ( $ARGV[0] eq '-' ) {
            $in_fasta_fh = *STDIN;
        }
        elsif ( -e $ARGV[0] ) {
            open $in_fasta_fh, "<", $ARGV[0]
              or die "cannot open file $ARGV[0]:$!\n";
        }
        else {
            die "$ARGV[0] does not exists\n";
        }
    }
    else {
        $in_fasta_fh = *STDIN;
    }
}

my %wv = ();
open my $wv_fh, "<", $wordvec_file or die "$!";
while (<$wv_fh>) {
    chomp;
    next if /^Uniprot/;
    my @item = split /\t/;
    my @ref  = @item[ 1 .. $#item ];
    $wv{ $item[0] } = \@ref;
}
close $wv_fh;

####Split fasta into different truncations
my $fasta_dir = $out_folder . "/fasta/";
mkdir $fasta_dir;

chomp( my @fastas = <$in_fasta_fh> );
close $in_fasta_fh;

my %fa   = ();
my $pro  = "";
my $flag = 0;

my $jobsize = 0+@fastas;
print_if_verbose("job size is $jobsize \n", $verbose);
foreach my $fasta (@fastas) {
    $fasta =~ s/\r//g;
    if ( $fasta =~ /^>(.*)/ ) {
        $pro = $1; # $1 is the last header found
        # Now $pro is the current header
        $pro =~ s/\s+|\*|\.|_|\[|\]|\"|\||\(|\)|\=//g;
        $pro = substr( $pro, 0, 15 );
        print_if_verbose("Starting vectorisation of $pro \n", $verbose);
        open my $pro_fh, ">>$fasta_dir" . "$pro.fasta" or die "$!";
        print $pro_fh ">", $pro, "\n";
        $fa{$pro}++;
        $flag++;
        close $pro_fh;
    }
    else {
        open my $pro_fh, ">>$fasta_dir" . "$pro.fasta" or die "$!";
        $fasta = uc $fasta;
        print $pro_fh "$fasta";
        close $pro_fh;
    }

}

print scalar keys %fa, "\n";
my $proNo = scalar keys %fa;
print_if_verbose("$proNo pro no variable\n", $verbose);
my $o_dir = $out_folder . "/ML/";
mkdir $o_dir;

# The length of the embedded vector
my $size = 60;

if ( $flag == 0 ) {
    $proNo = 1;
    $fa{"query"}++;
    open my $query_fh, ">$fasta_dir" . "query.fasta" or die "$!";
    print $query_fh ">query\n";
    foreach my $fasta (@fastas) {
        # Make the fasta uppercase
        $fasta = uc $fasta;
        print $query_fh "$fasta";
    }
    close $query_fh;
}

# Suddenly here we have the test input
if ( $proNo == 1 ) {
    $fa{"testSun"}++;
    system("cp $test_fa_file $fasta_dir");
    # the exit code that prints comes from here I think
    open my $Intestinput_fh, ">", "$o_dir" . "Intestinput.txt" or die "$!";
    open my $Intest_fh,      ">", "$o_dir" . "Intest.txt"      or die "$!";
    foreach my $uni ( sort keys %fa ) {
        my @fea      = ();
        my @vec      = ();
        my $bacfasta = "$fasta_dir" . "$uni.fasta";
        if ( !-s $bacfasta ) {
            print $bacfasta, "\t", "no bac protein\n";
            for ( my $j = 1 ; $j <= $size ; $j++ ) {
                push( @vec, 0 );
            }
        }
        else {
            open my $tmp_fh, $bacfasta or die "$!";
            chomp( my @bacteria_seq = <$tmp_fh> );
            close $tmp_fh;
            my @aa = split //, $bacteria_seq[1];
            for ( my $i = 0 ; $i < ( scalar @aa ) - 2 ; $i++ ) {
                my $tri = $aa[$i] . $aa[ $i + 1 ] . $aa[ $i + 2 ];
                if ( exists $wv{$tri} ) {
                    my @tvec = @{ $wv{$tri} };
                    for ( my $j = 0 ; $j < @tvec ; $j++ ) {
                        $vec[$j] += $tvec[$j];
                    }
                }

            }
        }
        push( @fea, @vec );
        print $Intestinput_fh "0\t", join "\t", @fea, "\n";
        print $Intest_fh "$uni\n";
    }
    close $Intestinput_fh;
    close $Intest_fh;
}
else {
    open my $Intestinput_fh, ">", "$o_dir" . "Intestinput.txt" or die "$!";
    open my $Intest_fh,      ">", "$o_dir" . "Intest.txt"      or die "$!";
    foreach my $uni ( sort keys %fa ) {
        my @fea      = ();
        my @vec      = ();
        my $bacfasta = "$fasta_dir" . "$uni.fasta";
        if ( !-s $bacfasta ) {
            print $bacfasta, "\t", "no bac protein\n";
            for ( my $j = 1 ; $j <= $size ; $j++ ) {
                push( @vec, 0 );
            }
        }
        else {
            open my $tmp_fh, $bacfasta or die "$!";
            chomp( my @bacteria_seq = <$tmp_fh> );
            close $tmp_fh;
            my @aa = split //, $bacteria_seq[1];
            for ( my $i = 0 ; $i < ( scalar @aa ) - 2 ; $i++ ) {
                my $tri = $aa[$i] . $aa[ $i + 1 ] . $aa[ $i + 2 ];
                if ( exists $wv{$tri} ) {
                    my @tvec = @{ $wv{$tri} };
                    for ( my $j = 0 ; $j < @tvec ; $j++ ) {
                        $vec[$j] += $tvec[$j];
                    }
                }

            }
        }
        push( @fea, @vec );
        print $Intestinput_fh "0\t", join "\t", @fea, "\n";
        print $Intest_fh "$uni\n";
    }
    close $Intestinput_fh;
    close $Intest_fh;
}

# We predict 100 models
for ( my $re = 1 ; $re <= 100 ; $re++ ) {
    my $f1_dir = "$train_wvc/$re/word2vec70_60/";
    my $f2_dir = $o_dir;
    # here the python stuff happens...
    system "python $Bin/Intest-apply-test.py $f1_dir $f2_dir $re";
    print_if_verbose("the Intest number $re is done... \n", $verbose);
}

my $n    = 0;
my %name = ();
open my $Intest_fh, "$o_dir" . "Intest.txt" or die "$!";
while (<$Intest_fh>) {
    chomp;
    $n++;
    $name{$n} = $_;
}
close $Intest_fh;

my %prob = ();
for ( my $re = 1 ; $re <= 100 ; $re++ ) {
    open my $tmp_fh, "$o_dir" . "InProbphase$re.txt" or die "$!";
    my $m = 0;
    while (<$tmp_fh>) {
        chomp;
        $m++;
        $prob{$m} += $_;
    }
    close $tmp_fh;
}


# Here we write the output summary
open my $avg_fh, ">", "$out_folder" . "Avg.txt" or die "$!";
print $avg_fh "ProteinName\tProb\n";
if ( $proNo == 1 ) {
    foreach my $name ( sort { $a <=> $b } keys %name ) {
        next if $name{$name} eq "testSun";
        print $avg_fh $name{$name}, "\t", $prob{$name} / 100, "\n";
    }
}
else {
    foreach my $name ( sort { $a <=> $b } keys %name ) {
        print $avg_fh $name{$name}, "\t", $prob{$name} / 100, "\n";
    }
}
close $avg_fh;
# l'heur d'amature... that is quite dangerous...
system "rm -rf $fasta_dir";
