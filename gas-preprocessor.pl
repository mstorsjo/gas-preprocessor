#!/usr/bin/env perl
# by David Conrad
# This code is licensed under GPLv2 or later; go to gnu.org to read it
#  (not that it much matters for an asm preprocessor)
# usage: set your assembler to be something like "perl gas-preprocessor.pl gcc"
use strict;

# Apple's gas is ancient and doesn't support modern preprocessing features like
# .rept and has ugly macro syntax, among other things. Thus, this script
# implements the subset of the gas preprocessor used by x264 and ffmpeg
# that isn't supported by Apple's gas.

my %canonical_arch = ("aarch64" => "aarch64", "arm64" => "aarch64",
                      "arm"     => "arm",
                      "powerpc" => "powerpc", "ppc"   => "powerpc");

my %comments = ("aarch64" => '//',
                "arm"     => '@',
                "ppc"     => '#',
                "powerpc" => '#');

my @gcc_cmd;
my @preprocess_c_cmd;

my $comm;
my $arch;
my $as_type = "apple-gas";

my $fix_unreq = $^O eq "darwin";
my $force_thumb = 0;
my $verbose = 0;

my $arm_cond_codes = "eq|ne|cs|cc|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al|hs|lo";

my $usage_str = "
$0\n
Gas-preprocessor.pl converts assembler files using modern GNU as syntax for
Apple's ancient gas version or clang's incompatible integrated assembler. The
conversion is regularly tested for FFmpeg, Libav, x264 and vlc. Other projects might
use different features which are not correctly handled.

Options for this program needs to be separated with ' -- ' from the assembler
command. Following options are currently supported:

    -help         - this usage text
    -arch         - target architecture
    -as-type      - one value out of {{,apple-}{gas,clang},armasm}
    -fix-unreq
    -no-fix-unreq
    -force-thumb  - assemble as thumb regardless of the input source
                    (note, this is incomplete and only works for sources
                    it explicitly was tested with)
    -verbose      - print executed commands
";

sub usage() {
    print $usage_str;
}

while (@ARGV) {
    my $opt = shift;

    if ($opt =~ /^-(no-)?fix-unreq$/) {
        $fix_unreq = $1 ne "no-";
    } elsif ($opt eq "-force-thumb") {
        $force_thumb = 1;
    } elsif ($opt eq "-verbose") {
        $verbose = 1;
    } elsif ($opt eq "-arch") {
        $arch = shift;
        die "unknown arch: '$arch'\n" if not exists $canonical_arch{$arch};
    } elsif ($opt eq "-as-type") {
        $as_type = shift;
        die "unknown as type: '$as_type'\n" if $as_type !~ /^((apple-)?(gas|clang|llvm_gcc)|armasm)$/;
    } elsif ($opt eq "-help") {
        usage();
        exit 0;
    } elsif ($opt eq "--" ) {
        @gcc_cmd = @ARGV;
    } elsif ($opt =~ /^-/) {
        die "option '$opt' is not known. See '$0 -help' for usage information\n";
    } else {
        push @gcc_cmd, $opt, @ARGV;
    }
    last if (@gcc_cmd);
}

if (grep /\.c$/, @gcc_cmd) {
    # C file (inline asm?) - compile
    @preprocess_c_cmd = (@gcc_cmd, "-S");
} elsif (grep /\.[sS]$/, @gcc_cmd) {
    # asm file, just do C preprocessor
    @preprocess_c_cmd = (@gcc_cmd, "-E");
} elsif (grep /-(v|h|-version|dumpversion)/, @gcc_cmd) {
    # pass -v/--version along, used during probing. Matching '-v' might have
    # uninteded results but it doesn't matter much if gas-preprocessor or
    # the compiler fails.
    print STDERR join(" ", @gcc_cmd)."\n" if $verbose;
    exec(@gcc_cmd);
} else {
    die "Unrecognized input filetype";
}
if ($as_type eq "armasm") {

    $preprocess_c_cmd[0] = "cpp";

    # Remove -ignore XX parameter pairs from preprocess_c_cmd
    my $index = 1;
    while ($index < $#preprocess_c_cmd) {
        if ($preprocess_c_cmd[$index] eq "-ignore" and $index + 1 < $#preprocess_c_cmd) {
            splice(@preprocess_c_cmd, $index, 2);
            next;
        }
        $index++;
    }
    if (grep /^-MM$/, @preprocess_c_cmd) {
        push(@preprocess_c_cmd, "-D_WIN32");
        # Normally a preprocessor for windows would predefine _WIN32,
        # but we're using any generic system-agnostic preprocessor "cpp"
        # with -undef (to avoid getting predefined variables from the host
        # system in cross compilation cases), so manually define it here.
        # We only use this generic preprocessor for generating dependencies,
        # if the build system runs preprocessing with -M/-MM without -MF.
        push(@preprocess_c_cmd, "-undef");
        @preprocess_c_cmd = grep ! /^-nologo$/, @preprocess_c_cmd;
        print STDERR join(" ", @preprocess_c_cmd)."\n" if $verbose;
        system(@preprocess_c_cmd) == 0 or die "Error running preprocessor";
        exit 0;
    }

    # If not preprocessing for getting a dependency list, use cl.exe
    # instead.
    $preprocess_c_cmd[0] = "cl.exe";
}

# if compiling, avoid creating an output file named '-.o'
if ((grep /^-c$/, @gcc_cmd) && !(grep /^-o/, @gcc_cmd)) {
    foreach my $i (@gcc_cmd) {
        if ($i =~ /\.[csS]$/) {
            my $outputfile = $i;
            $outputfile =~ s/\.[csS]$/.o/;
            push(@gcc_cmd, "-o");
            push(@gcc_cmd, $outputfile);
            last;
        }
    }
}
# Remove the -o argument; if omitted, we by default preprocess to stdout.
my $index = 1;
while ($index < $#preprocess_c_cmd) {
    if ($preprocess_c_cmd[$index] eq "-o") {
        splice(@preprocess_c_cmd, $index, 2);
        last;
    }
    $index++;
}

@preprocess_c_cmd = grep ! /^-c$/, @preprocess_c_cmd;

my $tempfile;
if ($as_type ne "armasm") {
    @gcc_cmd = map { /\.[csS]$/ ? qw(-x assembler -) : $_ } @gcc_cmd;

    # Filter out options that can cause warnings due to unused arguments,
    # Clang warns about unused -D parameters when invoked with "-x assembler".
    @gcc_cmd = grep ! /^-D/, @gcc_cmd;
} else {
    @preprocess_c_cmd = grep ! /^-m/, @preprocess_c_cmd;

    @preprocess_c_cmd = grep ! /^-G/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-W/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-Z/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-fp/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-EHsc$/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-O/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-oldit/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-FS/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-w/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-M/, @preprocess_c_cmd;
    @preprocess_c_cmd = grep ! /^-g/, @preprocess_c_cmd;

    @gcc_cmd = grep ! /^-G/, @gcc_cmd;
    @gcc_cmd = grep ! /^-W/, @gcc_cmd;
    @gcc_cmd = grep ! /^-Z/, @gcc_cmd;
    @gcc_cmd = grep ! /^-fp/, @gcc_cmd;
    @gcc_cmd = grep ! /^-EHsc$/, @gcc_cmd;
    @gcc_cmd = grep ! /^-O/, @gcc_cmd;
    @gcc_cmd = grep ! /^-FS/, @gcc_cmd;
    @gcc_cmd = grep ! /^-w/, @gcc_cmd;

    my @outfiles = grep /\.(o|obj)$/, @gcc_cmd;
    $tempfile = $outfiles[0].".asm";

    # Remove most parameters from gcc_cmd, which actually is the armasm command,
    # which doesn't support any of the common compiler/preprocessor options.
    @gcc_cmd = grep ! /^-D/, @gcc_cmd;
    @gcc_cmd = grep ! /^-U/, @gcc_cmd;
    @gcc_cmd = grep ! /^-m/, @gcc_cmd;
    @gcc_cmd = grep ! /^-M/, @gcc_cmd;
    @gcc_cmd = grep ! /^-c$/, @gcc_cmd;
    @gcc_cmd = grep ! /^-I/, @gcc_cmd;
    @gcc_cmd = map { /\.S$/ ? $tempfile : $_ } @gcc_cmd;
}

# detect architecture from gcc binary name
if (!$arch) {
    if ($gcc_cmd[0] =~ /(arm64|aarch64|arm|powerpc|ppc)/) {
        $arch = $1;
    } else {
        # look for -arch flag
        foreach my $i (1 .. $#gcc_cmd-1) {
            if ($gcc_cmd[$i] eq "-arch" and
                $gcc_cmd[$i+1] =~ /(arm64|aarch64|arm|powerpc|ppc)/) {
                $arch = $1;
            }
        }
    }
}

# assume we're not cross-compiling if no -arch or the binary doesn't have the arch name
$arch = qx/arch/ if (!$arch);
# remove any whitespace, e.g. arch command might print a newline
$arch =~ s/\s+//g;

die "Unknown target architecture '$arch'" if not exists $canonical_arch{$arch};

$arch = $canonical_arch{$arch};
$comm = $comments{$arch};
my $inputcomm = $comm;
$comm = ";" if $as_type =~ /armasm/;

my %ppc_spr = (ctr    => 9,
               vrsave => 256);

print STDERR join(" ", @preprocess_c_cmd)."\n" if $verbose;
open(INPUT, "-|", @preprocess_c_cmd) || die "Error running preprocessor";

if ($ENV{GASPP_DEBUG}) {
    open(ASMFILE, ">&STDOUT");
} else {
    if ($as_type ne "armasm") {
        print STDERR join(" ", @gcc_cmd)."\n" if $verbose;
        open(ASMFILE, "|-", @gcc_cmd) or die "Error running assembler";
    } else {
        open(ASMFILE, ">", $tempfile);
    }
}

my $current_macro = '';
my $macro_level = 0;
my $rept_level = 0;
my %macro_lines;
my %macro_args;
my %macro_args_default;
my $macro_count = 0;
my $altmacro = 0;
my $in_irp = 0;

my $num_repts;
my @rept_lines;

my @irp_args;
my $irp_param;

my @ifstack;

my %symbols;

my @sections;

my %literal_labels;     # for ldr <reg>, =<expr>
my $literal_num = 0;
my $literal_expr = ".word";
$literal_expr = ".quad" if $arch eq "aarch64";

my $thumb = 0;

my %thumb_labels;
my %call_targets;
my %import_symbols;

my %neon_alias_reg;
my %neon_alias_type;

my $temp_label_next = 0;
my %last_temp_labels;
my %next_temp_labels;

my %labels_seen;

my %aarch64_req_alias;

if ($force_thumb) {
    parse_line(".thumb\n");
}
if ($as_type eq "armasm") {
    parse_line(".text\n");
}

# pass 1: parse .macro
# note that the handling of arguments is probably overly permissive vs. gas
# but it should be the same for valid cases
while (<INPUT>) {
    # remove lines starting with '#', preprocessing is done, '#' at start of
    # the line indicates a comment for all supported archs (aarch64, arm, ppc
    # and x86). Also strips line number comments but since they are off anyway
    # it is no loss.
    s/^\s*#.*$//;
    # remove all comments (to avoid interfering with evaluating directives)
    s/(?<!\\)$inputcomm.*//x;
    # Strip out windows linefeeds
    s/\r$//;

    foreach my $subline (split(";", $_)) {
        chomp $subline;
        parse_line_continued($subline);
    }
}
parse_line_continued("");

sub eval_expr {
    my $expr = $_[0];
    while ($expr =~ /([A-Za-z._][A-Za-z0-9._]*)/g) {
        my $sym = $1;
        $expr =~ s/$sym/($symbols{$sym})/ if defined $symbols{$sym};
    }
    eval $expr;
}

sub handle_if {
    my $line = $_[0];
    # handle .if directives; apple's assembler doesn't support important non-basic ones
    # evaluating them is also needed to handle recursive macros
    if ($line =~ /\.if(n?)([a-z]*)\s+(.*)/) {
        my $result = $1 eq "n";
        my $type   = $2;
        my $expr   = $3;

        if ($type eq "b") {
            $expr =~ s/\s//g;
            $result ^= $expr eq "";
        } elsif ($type eq "c") {
            if ($expr =~ /(\S*)\s*,\s*(\S*)/) {
                $result ^= $1 eq $2;
            } else {
                die "argument to .ifc not recognized";
            }
        } elsif ($type eq "") {
            $result ^= eval_expr($expr) != 0;
        } elsif ($type eq "eq") {
            $result = eval_expr($expr) == 0;
        } elsif ($type eq "lt") {
            $result = eval_expr($expr) < 0;
        } else {
            chomp($line);
            die "unhandled .if variant. \"$line\"";
        }
        push (@ifstack, $result);
        return 1;
    } else {
        return 0;
    }
}

sub parse_if_line {
    my $line = $_[0];

    # evaluate .if blocks
    if (scalar(@ifstack)) {
        # Don't evaluate any new if statements if we're within
        # a repetition or macro - they will be evaluated once
        # the repetition is unrolled or the macro is expanded.
        if (scalar(@rept_lines) == 0 and $macro_level == 0) {
            if ($line =~ /\.endif/) {
                pop(@ifstack);
                return 1;
            } elsif ($line =~ /\.elseif\s+(.*)/) {
                if ($ifstack[-1] == 0) {
                    $ifstack[-1] = !!eval_expr($1);
                } elsif ($ifstack[-1] > 0) {
                    $ifstack[-1] = -$ifstack[-1];
                }
                return 1;
            } elsif ($line =~ /\.else/) {
                $ifstack[-1] = !$ifstack[-1];
                return 1;
            } elsif (handle_if($line)) {
                return 1;
            }
        }

        # discard lines in false .if blocks
        foreach my $i (0 .. $#ifstack) {
            if ($ifstack[$i] <= 0) {
                return 1;
            }
        }
    }
    return 0;
}

my $last_line = "";
sub parse_line_continued {
    my $line = $_[0];
    $last_line .= $line;
    if ($last_line =~ /\\$/) {
        $last_line =~ s/\\$//;
    } else {
        # Add newlines at the end of lines after concatenation.
        $last_line .= "\n";
        parse_line($last_line);
        $last_line = "";
    }
}

sub parse_line {
    my $line = $_[0];

    return if (parse_if_line($line));

    if (scalar(@rept_lines) == 0) {
        if ($line =~ /\.macro/) {
            $macro_level++;
            if ($macro_level > 1 && !$current_macro) {
                die "nested macros but we don't have master macro";
            }
        } elsif ($line =~ /\.endm/) {
            $macro_level--;
            if ($macro_level < 0) {
                die "unmatched .endm";
            } elsif ($macro_level == 0) {
                $current_macro = '';
                return;
            }
        }
    }

    if ($macro_level == 0) {
        if ($line =~ /\.(rept|irp)/) {
            $rept_level++;
        } elsif ($line =~ /.endr/) {
            $rept_level--;
        }
    }

    if ($macro_level > 1) {
        push(@{$macro_lines{$current_macro}}, $line);
    } elsif (scalar(@rept_lines) and $rept_level >= 1) {
        push(@rept_lines, $line);
    } elsif ($macro_level == 0) {
        expand_macros($line);
    } else {
        if ($line =~ /\.macro\s+([\d\w\.]+)\s*,?\s*(.*)/) {
            $current_macro = $1;

            # commas in the argument list are optional, so only use whitespace as the separator
            my $arglist = $2;
            $arglist =~ s/,/ /g;

            my @args = split(/\s+/, $arglist);
            foreach my $i (0 .. $#args) {
                my @argpair = split(/=/, $args[$i]);
                $macro_args{$current_macro}[$i] = $argpair[0];
                $argpair[0] =~ s/:vararg$//;
                $macro_args_default{$current_macro}{$argpair[0]} = $argpair[1];
            }
            # ensure %macro_lines has the macro name added as a key
            $macro_lines{$current_macro} = [];

        } elsif ($current_macro) {
            push(@{$macro_lines{$current_macro}}, $line);
        } else {
            die "macro level without a macro name";
        }
    }
}

sub handle_set {
    my $line = $_[0];
    if ($line =~ /\.(?:set|equ)\s+(\S*)\s*,\s*(.*)/) {
        $symbols{$1} = eval_expr($2);
        return 1;
    }
    return 0;
}

sub expand_macros {
    my $line = $_[0];

    # handle .if directives; apple's assembler doesn't support important non-basic ones
    # evaluating them is also needed to handle recursive macros
    if (handle_if($line)) {
        return;
    }

    if (/\.purgem\s+([\d\w\.]+)/) {
        delete $macro_lines{$1};
        delete $macro_args{$1};
        delete $macro_args_default{$1};
        return;
    }

    if ($line =~ /\.altmacro/) {
        $altmacro = 1;
        return;
    }

    if ($line =~ /\.noaltmacro/) {
        $altmacro = 0;
        return;
    }

    $line =~ s/\%([^,]*)/eval_expr($1)/eg if $altmacro;

    # Strip out the .set lines from the armasm output
    return if (handle_set($line) and $as_type eq "armasm");

    if ($line =~ /\.rept\s+(.*)/) {
        $num_repts = $1;
        @rept_lines = ("\n");

        # handle the possibility of repeating another directive on the same line
        # .endr on the same line is not valid, I don't know if a non-directive is
        if ($num_repts =~ s/(\.\w+.*)//) {
            push(@rept_lines, "$1\n");
        }
        $num_repts = eval_expr($num_repts);
    } elsif ($line =~ /\.irp\s+([\d\w\.]+)\s*(.*)/) {
        $in_irp = 1;
        $num_repts = 1;
        @rept_lines = ("\n");
        $irp_param = $1;

        # only use whitespace as the separator
        my $irp_arglist = $2;
        $irp_arglist =~ s/,/ /g;
        $irp_arglist =~ s/^\s+//;
        @irp_args = split(/\s+/, $irp_arglist);
    } elsif ($line =~ /\.irpc\s+([\d\w\.]+)\s*(.*)/) {
        $in_irp = 1;
        $num_repts = 1;
        @rept_lines = ("\n");
        $irp_param = $1;

        my $irp_arglist = $2;
        $irp_arglist =~ s/,/ /g;
        $irp_arglist =~ s/^\s+//;
        @irp_args = split(//, $irp_arglist);
    } elsif ($line =~ /\.endr/) {
        my @prev_rept_lines = @rept_lines;
        my $prev_in_irp = $in_irp;
        my @prev_irp_args = @irp_args;
        my $prev_irp_param = $irp_param;
        my $prev_num_repts = $num_repts;
        @rept_lines = ();
        $in_irp = 0;
        @irp_args = '';

        if ($prev_in_irp != 0) {
            foreach my $i (@prev_irp_args) {
                foreach my $origline (@prev_rept_lines) {
                    my $line = $origline;
                    $line =~ s/\\$prev_irp_param/$i/g;
                    $line =~ s/\\\(\)//g;     # remove \()
                    parse_line($line);
                }
            }
        } else {
            for (1 .. $prev_num_repts) {
                foreach my $origline (@prev_rept_lines) {
                    my $line = $origline;
                    parse_line($line);
                }
            }
        }
    } elsif ($line =~ /(\S+:|)\s*([\w\d\.]+)\s*(.*)/ && exists $macro_lines{$2}) {
        handle_serialized_line($1);
        my $macro = $2;

        # commas are optional here too, but are syntactically important because
        # parameters can be blank
        my @arglist = split(/,/, $3);
        my @args;
        my @args_seperator;

        my $comma_sep_required = 0;
        foreach (@arglist) {
            # allow arithmetic/shift operators in macro arguments
            $_ =~ s/\s*(\+|-|\*|\/|<<|>>|<|>)\s*/$1/g;

            my @whitespace_split = split(/\s+/, $_);
            if (!@whitespace_split) {
                push(@args, '');
                push(@args_seperator, '');
            } else {
                foreach (@whitespace_split) {
                        #print ("arglist = \"$_\"\n");
                    if (length($_)) {
                        push(@args, $_);
                        my $sep = $comma_sep_required ? "," : " ";
                        push(@args_seperator, $sep);
                        #print ("sep = \"$sep\", arg = \"$_\"\n");
                        $comma_sep_required = 0;
                    }
                }
            }

            $comma_sep_required = 1;
        }

        my %replacements;
        if ($macro_args_default{$macro}){
            %replacements = %{$macro_args_default{$macro}};
        }

        # construct hashtable of text to replace
        foreach my $i (0 .. $#args) {
            my $argname = $macro_args{$macro}[$i];
            my @macro_args = @{ $macro_args{$macro} };
            if ($args[$i] =~ m/=/) {
                # arg=val references the argument name
                # XXX: I'm not sure what the expected behaviour if a lot of
                # these are mixed with unnamed args
                my @named_arg = split(/=/, $args[$i]);
                $replacements{$named_arg[0]} = $named_arg[1];
            } elsif ($i > $#{$macro_args{$macro}}) {
                # more args given than the macro has named args
                # XXX: is vararg allowed on arguments before the last?
                $argname = $macro_args{$macro}[-1];
                if ($argname =~ s/:vararg$//) {
                    #print "macro = $macro, args[$i] = $args[$i], args_seperator=@args_seperator, argname = $argname, arglist[$i] = $arglist[$i], arglist = @arglist, args=@args, macro_args=@macro_args\n";
                    #$replacements{$argname} .= ", $args[$i]";
                    $replacements{$argname} .= "$args_seperator[$i] $args[$i]";
                } else {
                    die "Too many arguments to macro $macro";
                }
            } else {
                $argname =~ s/:vararg$//;
                $replacements{$argname} = $args[$i];
            }
        }

        my $count = $macro_count++;

        # apply replacements as regex
        foreach (@{$macro_lines{$macro}}) {
            my $macro_line = $_;
            # do replacements by longest first, this avoids wrong replacement
            # when argument names are subsets of each other
            foreach (reverse sort {length $a <=> length $b} keys %replacements) {
                $macro_line =~ s/\\$_/$replacements{$_}/g;
            }
            if ($altmacro) {
                foreach (reverse sort {length $a <=> length $b} keys %replacements) {
                    $macro_line =~ s/\b$_\b/$replacements{$_}/g;
                }
            }
            $macro_line =~ s/\\\@/$count/g;
            $macro_line =~ s/\\\(\)//g;     # remove \()
            parse_line($macro_line);
        }
    } else {
        handle_serialized_line($line);
    }
}

sub is_arm_register {
    my $name = $_[0];
    if ($name eq "lr" or
        $name eq "ip" or
        $name =~ /^[rav]\d+$/) {
        return 1;
    }
    return 0;
}

sub is_aarch64_register {
    my $name = $_[0];
    if ($name =~ /^[xw]\d+$/) {
        return 1;
    }
    return 0;
}

sub handle_local_label {
    my $line = $_[0];
    my $num  = $_[1];
    my $dir  = $_[2];
    my $target = "$num$dir";
    if ($dir eq "b") {
        $line =~ s/\b$target\b/$last_temp_labels{$num}/g;
    } else {
        my $name = "temp_label_$temp_label_next";
        $temp_label_next++;
        push(@{$next_temp_labels{$num}}, $name);
        $line =~ s/\b$target\b/$name/g;
    }
    return $line;
}

sub handle_serialized_line {
    my $line = $_[0];

    # handle .previous (only with regard to .section not .subsection)
    if ($line =~ /\.(section|text|const_data)/) {
        push(@sections, $line);
    } elsif ($line =~ /\.previous/) {
        if (!$sections[-2]) {
            die ".previous without a previous section";
        }
        $line = $sections[-2];
        push(@sections, $line);
    }

    $thumb = 1 if $line =~ /\.code\s+16|\.thumb/;
    $thumb = 0 if $line =~ /\.code\s+32|\.arm/;

    # handle ldr <reg>, =<expr>
    if ($line =~ /(.*)\s*ldr([\w\s\d]+)\s*,\s*=(.*)/ and $as_type ne "armasm") {
        my $label = $literal_labels{$3};
        if (!$label) {
            $label = "Literal_$literal_num";
            $literal_num++;
            $literal_labels{$3} = $label;
        }
        $line = "$1 ldr$2, $label\n";
    } elsif ($line =~ /\.ltorg/ and $as_type ne "armasm") {
        $line .= ".align 2\n";
        foreach my $literal (keys %literal_labels) {
            $line .= "$literal_labels{$literal}:\n $literal_expr $literal\n";
        }
        %literal_labels = ();
    }

    # handle GNU as pc-relative relocations for adrp/add
    if ($line =~ /(.*)\s*adrp([\w\s\d]+)\s*,\s*#?:pg_hi21:([^\s]+)/ and $as_type =~ /^apple-/) {
        $line = "$1 adrp$2, ${3}\@PAGE\n";
    } elsif ($line =~ /(.*)\s*add([\w\s\d]+)\s*,([\w\s\d]+)\s*,\s*#?:lo12:([^\s]+)/ and $as_type =~ /^apple-/) {
        $line = "$1 add$2, $3, ${4}\@PAGEOFF\n";
    }

    # thumb add with large immediate needs explicit add.w
    if ($thumb and $line =~ /add\s+.*#([^@]+)/) {
        $line =~ s/add/add.w/ if eval_expr($1) > 255;
    }

    # mach-o local symbol names start with L (no dot)
    # armasm also can't handle labels that start with a dot.
    if ($as_type =~ /apple-/ or $as_type eq "armasm") {
        $line =~ s/(?<!\w)\.(L\w+)/$1/g;
    }

    # recycle the '.func' directive for '.thumb_func'
    if ($thumb and $as_type =~ /^apple-/) {
        $line =~ s/\.func/.thumb_func/x;
    }

    if ($thumb and $line =~ /^\s*(\w+)\s*:/) {
        $thumb_labels{$1}++;
    }

    if ($as_type =~ /^apple-/ and
        $line =~ /^\s*((\w+\s*:\s*)?bl?x?(..)?(?:\.w)?|\.global)\s+(\w+)/) {
        my $cond = $3;
        my $label = $4;
        # Don't interpret e.g. bic as b<cc> with ic as conditional code
        if ($cond =~ /^(|$arm_cond_codes)$/) {
            if (exists $thumb_labels{$label}) {
                print ASMFILE ".thumb_func $label\n";
            } else {
                $call_targets{$label}++;
            }
        }
    }

    # @l -> lo16()  @ha -> ha16()
    $line =~ s/,\s+([^,]+)\@l\b/, lo16($1)/g;
    $line =~ s/,\s+([^,]+)\@ha\b/, ha16($1)/g;

    # move to/from SPR
    if ($line =~ /(\s+)(m[ft])([a-z]+)\s+(\w+)/ and exists $ppc_spr{$3}) {
        if ($2 eq 'mt') {
            $line = "$1${2}spr $ppc_spr{$3}, $4\n";
        } else {
            $line = "$1${2}spr $4, $ppc_spr{$3}\n";
        }
    }

    if ($line =~ /\.unreq\s+(.*)/) {
        if (defined $neon_alias_reg{$1}) {
            delete $neon_alias_reg{$1};
            delete $neon_alias_type{$1};
            return;
        } elsif (defined $aarch64_req_alias{$1}) {
            delete $aarch64_req_alias{$1};
            return;
        }
    }
    # old gas versions store upper and lower case names on .req,
    # but they remove only one on .unreq
    if ($fix_unreq) {
        if ($line =~ /\.unreq\s+(.*)/) {
            $line = ".unreq " . lc($1) . "\n";
            $line .= ".unreq " . uc($1) . "\n";
        }
    }

    if ($line =~ /(\w+)\s+\.(dn|qn)\s+(\w+)(?:\.(\w+))?(\[\d+\])?/) {
        $neon_alias_reg{$1} = "$3$5";
        $neon_alias_type{$1} = $4;
        return;
    }
    if (scalar keys %neon_alias_reg > 0 && $line =~ /^\s+v\w+/) {
        # This line seems to possibly have a neon instruction
        foreach (keys %neon_alias_reg) {
            my $alias = $_;
            # Require the register alias to match as an individual word, not as a substring
            # of a larger word-token.
            if ($line =~ /\b$alias\b/) {
                $line =~ s/\b$alias\b/$neon_alias_reg{$alias}/g;
                # Add the type suffix. If multiple aliases match on the same line,
                # only do this replacement the first time (a vfoo.bar string won't match v\w+).
                $line =~ s/^(\s+)(v\w+)(\s+)/$1$2.$neon_alias_type{$alias}$3/;
            }
        }
    }

    if ($arch eq "aarch64" or $as_type eq "armasm") {
        # clang's integrated aarch64 assembler in Xcode 5 does not support .req/.unreq
        if ($line =~ /\b(\w+)\s+\.req\s+(\w+)\b/) {
            $aarch64_req_alias{$1} = $2;
            return;
        }
        foreach (keys %aarch64_req_alias) {
            my $alias = $_;
            # recursively resolve aliases
            my $resolved = $aarch64_req_alias{$alias};
            while (defined $aarch64_req_alias{$resolved}) {
                $resolved = $aarch64_req_alias{$resolved};
            }
            $line =~ s/\b$alias\b/$resolved/g;
        }
    }
    if ($arch eq "aarch64") {
        # fix missing aarch64 instructions in Xcode 5.1 (beta3)
        # mov with vector arguments is not supported, use alias orr instead
        if ($line =~ /^(\d+:)?\s*mov\s+(v\d[\.{}\[\]\w]+),\s*(v\d[\.{}\[\]\w]+)\b\s*$/) {
            $line = "$1        orr $2, $3, $3\n";
        }
        # movi 16, 32 bit shifted variant, shift is optional
        if ($line =~ /^(\d+:)?\s*movi\s+(v[0-3]?\d\.(?:2|4|8)[hsHS])\s*,\s*(#\w+)\b\s*$/) {
            $line = "$1        movi $2, $3, lsl #0\n";
        }
        # Xcode 5 misses the alias uxtl. Replace it with the more general ushll.
        # Clang 3.4 misses the alias sxtl too. Replace it with the more general sshll.
        # armasm64 also misses these instructions.
        if ($line =~ /^(\d+:)?\s*(s|u)xtl(2)?\s+(v[0-3]?\d\.[248][hsdHSD])\s*,\s*(v[0-3]?\d\.(?:2|4|8|16)[bhsBHS])\b\s*$/) {
            $line = "$1        $2shll$3 $4, $5, #0\n";
        }
        # clang 3.4 and armasm64 do not automatically use shifted immediates in add/sub
        if (($as_type eq "clang" or $as_type eq "armasm") and
            $line =~ /^(\d+:)?(\s*(?:add|sub)s?) ([^#l]+)#([\d\+\-\*\/ <>]+)\s*$/) {
            my $imm = eval $4;
            if ($imm > 4095 and not ($imm & 4095)) {
                $line = "$1 $2 $3#" . ($imm >> 12) . ", lsl #12\n";
            }
        }
        if ($ENV{GASPP_FIX_XCODE5}) {
            if ($line =~ /^\s*bsl\b/) {
                $line =~ s/\b(bsl)(\s+v[0-3]?\d\.(\w+))\b/$1.$3$2/;
                $line =~ s/\b(v[0-3]?\d)\.$3\b/$1/g;
            }
            if ($line =~ /^\s*saddl2?\b/) {
                $line =~ s/\b(saddl2?)(\s+v[0-3]?\d\.(\w+))\b/$1.$3$2/;
                $line =~ s/\b(v[0-3]?\d)\.\w+\b/$1/g;
            }
            if ($line =~ /^\s*dup\b.*\]$/) {
                $line =~ s/\bdup(\s+v[0-3]?\d)\.(\w+)\b/dup.$2$1/g;
                $line =~ s/\b(v[0-3]?\d)\.[bhsdBHSD](\[\d\])$/$1$2/g;
            }
        }
    }

    if ($as_type eq "armasm") {
        # Also replace variables set by .set
        foreach (keys %symbols) {
            my $sym = $_;
            $line =~ s/\b$sym\b/$symbols{$sym}/g;
        }

        # Handle function declarations and keep track of the declared labels
        if ($line =~ s/^\s*\.func\s+(\w+)/$1 PROC/) {
            $labels_seen{$1} = 1;
        }

        if ($line =~ s/^\s*(\d+)://) {
            # Convert local labels into unique labels. armasm (at least in
            # RVCT) has something similar, but still different enough.
            # By converting to unique labels we avoid any possible
            # incompatibilities.

            my $num = $1;
            foreach (@{$next_temp_labels{$num}}) {
                $line = "$_\n" . $line;
            }
            @next_temp_labels{$num} = ();
            my $name = "temp_label_$temp_label_next";
            $temp_label_next++;
            # The matching regexp above removes the label from the start of
            # the line (which might contain an instruction as well), re-add
            # it on a separate line above it.
            $line = "$name:\n" . $line;
            $last_temp_labels{$num} = $name;
        }

        if ($line =~ s/^\s*(\w+):/$1/) {
            # Skip labels that have already been declared with a PROC,
            # labels must not be declared multiple times.
            return if (defined $labels_seen{$1});
            $labels_seen{$1} = 1;
        } elsif ($line !~ /(\w+) PROC/) {
            # If not a label, make sure the line starts with whitespace,
            # otherwise ms armasm interprets it incorrectly.
            $line =~ s/^[\.\w]/\t$&/;
        }


        # Check branch instructions
        if ($line =~ /(?:^|\n)\s*(\w+\s*:\s*)?(bl?x?\.?([^\s]{2})?(\.w)?)\s+(\w+)/) {
            my $instr = $2;
            my $cond = $3;
            my $width = $4;
            my $target = $5;
            # Don't interpret e.g. bic as b<cc> with ic as conditional code
            if ($cond !~ /^(|$arm_cond_codes)$/) {
                # Not actually a branch
            } elsif ($target =~ /^(\d+)([bf])$/) {
                # The target is a local label
                $line = handle_local_label($line, $1, $2);
                $line =~ s/\b$instr\b/$&.w/ if $width eq "" and $arch eq "arm";
            } elsif (($arch eq "arm" and !is_arm_register($target)) or
                     ($arch eq "aarch64" and !is_aarch64_register($target))) {
                $call_targets{$target}++;
            }
        } elsif ($line =~ /(?:^|\n)\s*(\w+\s*:\s*)?(cbn?z|adr|tbn?z)\s+(\w+)\s*,(\s*#\d+\s*,)?\s*(\w+)/) {
            my $instr = $2;
            my $reg = $3;
            my $bit = $4;
            my $target = $5;
            if ($target =~ /^(\d+)([bf])$/) {
                # The target is a local label
                $line = handle_local_label($line, $1, $2);
            } else {
                $call_targets{$target}++;
            }
            # Convert tbz with a wX register into an xX register,
            # due to armasm64 bugs/limitations.
            if (($instr eq "tbz" or $instr eq "tbnz") and $reg =~ /w\d+/) {
                my $xreg = $reg;
                $xreg =~ s/w/x/;
                $line =~ s/\b$reg\b/$xreg/;
            }
        } elsif ($line =~ /^\s*.([hxd]?word|quad).*\b\d+[bf]\b/) {
            while ($line =~ /\b(\d+)([bf])\b/g) {
                $line = handle_local_label($line, $1, $2);
            }
        }

        # ALIGN in armasm syntax is the actual number of bytes
        if ($line =~ /\.(?:p2)?align\s+(\d+)/) {
            my $align = 1 << $1;
            $line =~ s/\.(?:p2)?align\s+(\d+)/ALIGN $align/;
        }
        # Convert gas style [r0, :128] into armasm [r0@128] alignment specification
        $line =~ s/\[([^\[,]+),?\s*:(\d+)\]/[$1\@$2]/g;

        # armasm treats logical values {TRUE} and {FALSE} separately from
        # numeric values - logical operators and values can't be intermixed
        # with numerical values. Evaluate !<number> and (a <> b) into numbers,
        # let the assembler evaluate the rest of the expressions. This current
        # only works for cases when ! and <> are used with actual constant numbers,
        # we don't evaluate subexpressions here.

        # Evaluate !<number>
        while ($line =~ /!\s*(\d+)/g) {
            my $val = ($1 != 0) ? 0 : 1;
            $line =~ s/!(\d+)/$val/;
        }
        # Evaluate (a > b)
        while ($line =~ /\(\s*(\d+)\s*([<>])\s*(\d+)\s*\)/) {
            my $val;
            if ($2 eq "<") {
                $val = ($1 < $3) ? 1 : 0;
            } else {
                $val = ($1 > $3) ? 1 : 0;
            }
            $line =~ s/\(\s*(\d+)\s*([<>])\s*(\d+)\s*\)/$val/;
        }

        if ($arch eq "arm") {
            # Change a movw... #:lower16: into a mov32 pseudoinstruction
            $line =~ s/^(\s*)movw(\s+\w+\s*,\s*)\#:lower16:(.*)$/$1mov32$2$3/;
            # and remove the following, matching movt completely
            $line =~ s/^\s*movt\s+\w+\s*,\s*\#:upper16:.*$//;

            if ($line =~ /^\s*mov32\s+\w+,\s*([a-zA-Z]\w*)/) {
                $import_symbols{$1}++;
            }

            # Misc bugs/deficiencies:
            # armasm seems unable to parse e.g. "vmov s0, s1" without a type
            # qualifier, thus add .f32.
            $line =~ s/^(\s+(?:vmov|vadd))(\s+s\d+\s*,\s*s\d+)/$1.f32$2/;
        } elsif ($arch eq "aarch64") {
            # Convert ext into ext8; armasm64 seems to require it named as ext8.
            $line =~ s/^(\s+)ext(\s+)/$1ext8$2/;

            # Pick up targets from ldr x0, =sym+offset
            if ($line =~ /^\s*ldr\s+(\w+)\s*,\s*=([a-zA-Z]\w*)(.*)$/) {
                my $reg = $1;
                my $sym = $2;
                my $offset = eval_expr($3);
                if ($offset < 0 and $ENV{GASPP_ARMASM64_SKIP_NEG_OFFSET}) {
                    # armasm64 in VS < 15.6 is buggy with ldr x0, =sym+offset where the
                    # offset is a negative value; it does write a negative
                    # offset into the literal pool as it should, but the
                    # negative offset only covers the lower 32 bit of the 64
                    # bit literal/relocation.
                    # Thus remove the offset and apply it manually with a sub
                    # afterwards.
                    $offset = -$offset;
                    $line = "\tldr $reg, =$sym\n\tsub $reg, $reg, #$offset\n";
                }
                $import_symbols{$sym}++;
            }

            # armasm64 (currently) doesn't support offsets on adrp targets,
            # even though the COFF format relocations (and the linker)
            # supports it. Therefore strip out the offsets from adrp and
            # add :lo12: (in case future armasm64 would start handling it)
            # and add an extra explicit add instruction for the offset.
            if ($line =~ s/(adrp\s+\w+\s*,\s*(\w+))([\d\+\-\*\/\(\) <>]+)?/\1/) {
                $import_symbols{$2}++;
            }
            if ($line =~ s/(add\s+(\w+)\s*,\s*\w+\s*,\s*):lo12:(\w+)([\d\+\-\*\/\(\) <>]+)?/\1\3/) {
                my $reg = $2;
                my $sym = $3;
                my $offset = eval_expr($4);
                $line .= "\tadd $reg, $reg, #$offset\n" if $offset > 0;
                $import_symbols{$sym}++;
            }

            # Convert e.g. "add x0, x0, w0, uxtw" into "add x0, x0, w0, uxtw #0",
            # or "ldr x0, [x0, w0, uxtw]" into "ldr x0, [x0, w0, uxtw #0]".
            $line =~ s/(uxt[whb]|sxt[whb])(\s*\]?\s*)$/\1 #0\2/i;

            # Convert "mov x0, v0.d[0]" into "umov x0, v0.d[0]"
            $line =~ s/\bmov\s+[xw]\d+\s*,\s*v\d+\.[ds]/u$&/i;

            # Convert "ccmp w0, #0, #0, ne" into "ccmpne w0, #0, #0",
            # and "csel w0, w0, w0, ne" into "cselne w0, w0, w0".
            $line =~ s/(ccmp|csel)\s+([xw]\w+)\s*,\s*([xw#]\w+)\s*,\s*([xw#]\w+)\s*,\s*($arm_cond_codes)/\1\5 \2, \3, \4/;

            # Convert "cinc w0, w0, ne" into "cincne w0, w0".
            $line =~ s/(cinc)\s+([xw]\w+)\s*,\s*([xw]\w+)\s*,\s*($arm_cond_codes)/\1\4 \2, \3/;

            # Convert "cset w0, lo" into "csetlo w0"
            $line =~ s/(cset)\s+([xw]\w+)\s*,\s*($arm_cond_codes)/\1\3 \2/;

            if ($ENV{GASPP_ARMASM64_SKIP_PRFUM}) {
                # Strip out prfum; armasm64 (VS < 15.5) fails to assemble any
                # variant/combination of prfum tested so far, but since it is
                # a prefetch instruction it can be skipped without changing
                # results.
                $line =~ s/prfum.*\]//;
            }

            # Convert "ldrb w0, [x0, #-1]" into "ldurb w0, [x0, #-1]".
            # Don't do this for forms with writeback though.
            if ($line =~ /(ld|st)(r[bh]?)\s+(\w+)\s*,\s*\[\s*(\w+)\s*,\s*#([^\]]+)\s*\][^!]/) {
                my $instr = $1;
                my $suffix = $2;
                my $target = $3;
                my $base = $4;
                my $offset = eval_expr($5);
                if ($offset < 0) {
                    $line =~ s/$instr$suffix/${instr}u$suffix/;
                }
            }

            if ($ENV{GASPP_ARMASM64_INVERT_SCALE}) {
                # Instructions like fcvtzs and scvtf store the scale value
                # inverted in the opcode (stored as 64 - scale), but armasm64
                # in VS < 15.5 stores it as-is. Thus convert from
                # "fcvtzs w0, s0, #8" into "fcvtzs w0, s0, #56".
                if ($line =~ /(?:fcvtzs|scvtf)\s+(\w+)\s*,\s*(\w+)\s*,\s*#(\d+)/) {
                    my $scale = $3;
                    my $inverted_scale = 64 - $3;
                    $line =~ s/#$scale/#$inverted_scale/;
                }
            }

            # Convert "ld1 {v0.4h-v3.4h}" into "ld1 {v0.4h,v1.4h,v2.4h,v3.4h}"
            if ($line =~ /(\{\s*v(\d+)\.(\d+[bhsdBHSD])\s*-\s*v(\d+)\.(\d+[bhsdBHSD])\s*\})/) {
                my $regspec = $1;
                my $reg1 = $2;
                my $layout1 = $3;
                my $reg2 = $4;
                my $layout2 = $5;
                if ($layout1 eq $layout2) {
                    my $new_regspec = "{";
                    foreach my $i ($reg1 .. $reg2) {
                        $new_regspec .= "," if ($i > $reg1);
                        $new_regspec .= "v$i.$layout1";
                    }
                    $new_regspec .= "}";
                    $line =~ s/$regspec/$new_regspec/;
                }
            }
        }
        # armasm is unable to parse &0x - add spacing
        $line =~ s/&0x/& 0x/g;
    }

    if ($force_thumb) {
        # Convert register post indexing to a separate add instruction.
        # This converts e.g. "ldr r0, [r1], r2" into "ldr r0, [r1]",
        # "add r1, r1, r2".
        $line =~ s/((?:ldr|str)[bh]?)\s+(\w+),\s*\[(\w+)\],\s*(\w+)/$1 $2, [$3]\n\tadd $3, $3, $4/g;

        # Convert "mov pc, lr" into "bx lr", since the former only works
        # for switching from arm to thumb (and only in armv7), but not
        # from thumb to arm.
        $line =~ s/mov\s*pc\s*,\s*lr/bx lr/g;

        # Convert stmdb/ldmia/stmfd/ldmfd/ldm with only one register into a plain str/ldr with post-increment/decrement.
        # Wide thumb2 encoding requires at least two registers in register list while all other encodings support one register too.
        $line =~ s/stm(?:db|fd)\s+sp!\s*,\s*\{([^,-]+)\}/str $1, [sp, #-4]!/g;
        $line =~ s/ldm(?:ia|fd)?\s+sp!\s*,\s*\{([^,-]+)\}/ldr $1, [sp], #4/g;

        # Convert muls into mul+cmp
        $line =~ s/muls\s+(\w+),\s*(\w+)\,\s*(\w+)/mul $1, $2, $3\n\tcmp $1, #0/g;

        # Convert "and r0, sp, #xx" into "mov r0, sp", "and r0, r0, #xx"
        $line =~ s/and\s+(\w+),\s*(sp|r13)\,\s*#(\w+)/mov $1, $2\n\tand $1, $1, #$3/g;

        # Convert "ldr r0, [r0, r1, lsl #6]" where the shift is >3 (which
        # can't be handled in thumb) into "add r0, r0, r1, lsl #6",
        # "ldr r0, [r0]", for the special case where the same address is
        # used as base and target for the ldr.
        if ($line =~ /(ldr[bh]?)\s+(\w+),\s*\[\2,\s*(\w+),\s*lsl\s*#(\w+)\]/ and $4 > 3) {
            $line =~ s/(ldr[bh]?)\s+(\w+),\s*\[\2,\s*(\w+),\s*lsl\s*#(\w+)\]/add $2, $2, $3, lsl #$4\n\t$1 $2, [$2]/;
        }

        $line =~ s/\.arm/.thumb/x;
    }

    # comment out unsupported directives
    $line =~ s/\.type/$comm$&/x        if $as_type =~ /^(apple-|armasm)/;
    $line =~ s/\.func/$comm$&/x        if $as_type =~ /^(apple-|clang)/;
    $line =~ s/\.endfunc/$comm$&/x     if $as_type =~ /^(apple-|clang)/;
    $line =~ s/\.endfunc/ENDP/x        if $as_type =~ /armasm/;
    $line =~ s/\.ltorg/$comm$&/x       if $as_type =~ /^(apple-|clang)/;
    $line =~ s/\.ltorg/LTORG/x         if $as_type eq "armasm";
    $line =~ s/\.size/$comm$&/x        if $as_type =~ /^(apple-|armasm)/;
    $line =~ s/\.fpu/$comm$&/x         if $as_type =~ /^(apple-|armasm)/;
    $line =~ s/\.arch/$comm$&/x        if $as_type =~ /^(apple-|clang|armasm)/;
    $line =~ s/\.object_arch/$comm$&/x if $as_type =~ /^(apple-|armasm)/;
    $line =~ s/.section\s+.note.GNU-stack.*/$comm$&/x if $as_type =~ /^(apple-|armasm)/;

    $line =~ s/\.syntax/$comm$&/x      if $as_type =~ /armasm/;

    $line =~ s/\.hword/.short/x;
    $line =~ s/\.xword/.quad/x;
    $line =~ s/\.dword/.quad/x;

    if ($as_type =~ /^apple-/) {
        # the syntax for these is a little different
        $line =~ s/\.global/.globl/x;
        # also catch .section .rodata since the equivalent to .const_data is .section __DATA,__const
        $line =~ s/(.*)\.rodata/.const_data/x;
        $line =~ s/\.int/.long/x;
        $line =~ s/\.float/.single/x;
    }
    if ($as_type eq "apple-gas") {
        $line =~ s/vmrs\s+APSR_nzcv/fmrx r15/x;
    }
    if ($as_type eq "armasm") {
        $line =~ s/\.global/EXPORT/x;
        $line =~ s/\.extern/IMPORT/x;
        $line =~ s/\.int/dcd/x;
        $line =~ s/\.long/dcd/x;
        $line =~ s/\.float/dcfs/x;
        $line =~ s/\.word/dcd/x;
        $line =~ s/\.short/dcw/x;
        $line =~ s/\.byte/dcb/x;
        $line =~ s/\.quad/dcq/x;
        $line =~ s/\.ascii/dcb/x;
        $line =~ s/\.asciz(.*)$/dcb\1,0/x;
        $line =~ s/\.thumb/THUMB/x;
        $line =~ s/\.arm/ARM/x;
        # The alignment in AREA is the power of two, just as .align in gas
        $line =~ s/\.text/AREA |.text|, CODE, READONLY, ALIGN=4, CODEALIGN/;
        $line =~ s/(\s*)(.*)\.ro?data(\s*,\s*"\w+")?/$1AREA |.rdata|, DATA, READONLY, ALIGN=5/;
        $line =~ s/\.data/AREA |.data|, DATA, ALIGN=5/;
    }
    if ($as_type eq "armasm" and $arch eq "arm") {
        $line =~ s/fmxr/vmsr/;
        $line =~ s/fmrx/vmrs/;
        $line =~ s/fadds/vadd.f32/;
        # Armasm in VS 2019 16.3 errors out on "it" instructions. But
        # armasm implicitly adds the necessary it instructions anyway, so we
        # can just filter them out.
        $line =~ s/^\s*it[te]*\s+/$comm$&/;
    }
    if ($as_type eq "armasm" and $arch eq "aarch64") {
        # Convert "b.eq" into "beq"
        $line =~ s/\bb\.($arm_cond_codes)\b/b\1/;
    }

    # catch unknown section names that aren't mach-o style (with a comma)
    if ($as_type =~ /apple-/ and $line =~ /.section ([^,]*)$/) {
        die ".section $1 unsupported; figure out the mach-o section name and add it";
    }

    print ASMFILE $line;
}

if ($as_type ne "armasm") {
    print ASMFILE ".text\n";
    print ASMFILE ".align 2\n";
    foreach my $literal (keys %literal_labels) {
        print ASMFILE "$literal_labels{$literal}:\n $literal_expr $literal\n";
    }

    map print(ASMFILE ".thumb_func $_\n"),
        grep exists $thumb_labels{$_}, keys %call_targets;
} else {
    map print(ASMFILE "\tIMPORT $_\n"),
        grep ! exists $labels_seen{$_}, (keys %call_targets, keys %import_symbols);

    print ASMFILE "\tEND\n";
}

close(INPUT) or exit 1;
close(ASMFILE) or exit 1;
if ($as_type eq "armasm" and ! defined $ENV{GASPP_DEBUG}) {
    print STDERR join(" ", @gcc_cmd)."\n" if $verbose;
    system(@gcc_cmd) == 0 or die "Error running assembler";
}

END {
    unlink($tempfile) if defined $tempfile;
}
#exit 1
