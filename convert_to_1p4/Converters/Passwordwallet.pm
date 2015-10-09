# PasswordWallet CSV export converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Passwordwallet 1.01;

our @ISA 	= qw(Exporter);
our @EXPORT     = qw(do_init do_import do_export);
our @EXPORT_OK  = qw();

use v5.14;
use utf8;
use strict;
use warnings;
#use diagnostics;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use Utils::PIF;
use Utils::Utils qw(verbose debug bail pluralize myjoin print_record);
use Text::CSV;


my %card_field_specs = (
    login =>			{ textname => '', fields => [
	[ 'title',		0, qr/^title$/, ],
	[ 'username',		0, qr/^username$/, ],
	[ 'password',		0, qr/^password$/, ],
	[ 'url',		0, qr/^url$/, ],
	[ 'notes',		0, qr/^notes$/, ],
    ]},
    note =>			{ textname => '', fields => [
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [],
    }
}

sub do_import {
    my ($file, $imptypes) = @_;

    my $csv = Text::CSV->new ({
	    binary => 1,
	    allow_loose_quotes => 1,
	    sep_char => "\t",
	    eol => "\n",
    });

    open my $io, $^O eq 'MSWin32' ? "<:encoding(utf16LE)" : "<:encoding(utf8)", $file
	or bail "Unable to open CSV file: $file\n$!";

    my %Cards;
    my ($n, $rownum) = (1, 1);
    my ($npre_explode, $npost_explode);

    $csv->column_names(qw/title url username password notes category browser unused1 unused2/);
    while (my $row = $csv->getline_hr($io)) {
	debug 'ROW: ', $rownum++;

	my $itype = find_card_type($row);

	next if defined $imptypes and (! exists $imptypes->{$itype});

	# Grab the special fields and delete them from the row
	my ($card_title, $card_notes, $card_tags) = @$row{qw/title notes category/};
	delete @$row{qw/title notes category/};

	my @fieldlist;

	# handle the special auto-type characters in username and password
	#
	# • Unicode: U+2022, UTF-8: E2 80 A2		pass,user: tab to next field
	# ¶ Unicode: U+00B6, UTF-8: C2 B6		pass,user: carriage return, does auto-submit
	# § Unicode: U+00A7, UTF-8: C2 A7		pass,user: adds delay
	# ∞ Unicode: U+221E, UTF-8: E2 88 9E		pass,user: pause/resume auto-type
	# « Unicode: U+00AB, UTF-8: C2 AB		pass,user: reverse tab
	#
	# pass through - referent Title may not be unique
	# [:OtherEntryName:]				pass,login: uses value from the named entry

	for (qw/username password/) {
	    next unless $row->{$_} =~ /[\x{2022}\x{00B6}\x{00A7}\x{221E}\x{00AB}]/;

	    $row->{$_} =~ s/(?:\x{00A7}|\x{221E})//g;				# strip globally: delay, pause/resume
	    $row->{$_} =~ s/(?:\x{2022}|\x{00B6}|\x{00AB})+$//;			# strip from end: tab/reverse tab, auto-submit
	    $row->{$_} =~ s/^(?:\x{2022}|\x{00B6}|\x{00AB})+//;			# strip from beginning: tab/reverse tab, auto-submit

	    if ($row->{$_} =~ s/^(.+?)(?:\x{2022}|\x{00AB})+(.*)$/$1/) {	# split at tab-to-next-field char
		my @a = split /(?:\x{2022}|\x{00AB})+/, $2;
		for (my $i = 1; $i <= @a; $i++) {
		    push @fieldlist, [ join('_', $_ , 'part', $i + 1)  =>  $a[$i - 1] ];
		}
	    }

	    $row->{$_} =~ s/[\x{2022}\x{00B6}\x{00A7}\x{221E}\x{00AB}]//g;	# strip all remaining metcharacters now
	}

	# Everything that remains in the row is the field data
	for (keys %$row) {
	    debug "\tcust field: $_ => $row->{$_}";
	    push @fieldlist, [ $_ => $row->{$_} ];
	}

	my $normalized = normalize_card_data($itype, \@fieldlist, 
	    { title	=> $card_title,
	      notes	=> $card_notes =~ s/\x{00AC}/\n/gr,		# translate encoded newline: ¬ Unicode: U+00AC, UTF-8: C2 AC
	      tags	=> $card_tags });

	# Returns list of 1 or more card/type hashes; one input card may explode into multiple output cards
	my $cardlist = explode_normalized($itype, $normalized);

	my @k = keys %$cardlist;
	if (@k > 1) {
	    $npre_explode++; $npost_explode += @k;
	    debug "\tcard type $itype expanded into ", scalar @k, " cards of type @k"
	}
	for (@k) {
	    print_record($cardlist->{$_});
	    push @{$Cards{$_}}, $cardlist->{$_};
	}
	$n++;
    }
    if (! $csv->eof()) {
	warn "Unexpected failure parsing CSV: row $n";
    }

    $n--;
    verbose "Imported $n card", pluralize($n) ,
	$npre_explode ? " ($npre_explode card" . pluralize($npre_explode) .  " expanded to $npost_explode cards)" : "";
    return \%Cards;
}

sub do_export {
    create_pif_file(@_);
}

# Places card data into a normalized internal form.
#
# Basic card data passed as $norm_cards hash ref:
#    title
#    notes
#    tags
#    folder
#    modified
# Per-field data hash {
#    inkey	=> imported field name
#    value	=> field value after callback processing
#    valueorig	=> original field value
#    outkey	=> exported field name
#    outtype	=> field's output type (may be different than card's output type)
#    keep	=> keep inkey:valueorig pair can be placed in notes
#    to_title	=> append title with a value from the narmalized card
# }
sub normalize_card_data {
    my ($type, $fieldlist, $norm_cards) = @_;

    for my $def (@{$card_field_specs{$type}{'fields'}}) {
	my $h = {};
	for (my $i = 0; $i < @$fieldlist; $i++) {
	    my ($inkey, $value) = @{$fieldlist->[$i]};
	    next if not defined $value or $value eq '';

	    if ($inkey =~ $def->[2]) {
		my $origvalue = $value;

		if (exists $def->[3] and exists $def->[3]{'func'}) {
		    #         callback(value, outkey)
		    my $ret = ($def->[3]{'func'})->($value, $def->[0]);
		    $value = $ret	if defined $ret;
		}
		$h->{'inkey'}		= $inkey;
		$h->{'value'}		= $value;
		$h->{'valueorig'}	= $origvalue;
		$h->{'outkey'}		= $def->[0];
		$h->{'outtype'}		= $def->[3]{'type_out'} || $card_field_specs{$type}{'type_out'} || $type; 
		$h->{'keep'}		= $def->[3]{'keep'} // 0;
		$h->{'to_title'}	= ' - ' . $h->{$def->[3]{'to_title'}}	if $def->[3]{'to_title'};
		push @{$norm_cards->{'fields'}}, $h;
		splice @$fieldlist, $i, 1;	# delete matched so undetected are pushed to notes below
		last;
	    }
	}
    }

    # map remaining keys to notes
    $norm_cards->{'notes'} .= "\n"	if defined $norm_cards->{'notes'} and length $norm_cards->{'notes'} > 0 and @$fieldlist;
    for (@$fieldlist) {
	next if $_->[1] eq '';
	$norm_cards->{'notes'} .= "\n"	if defined $norm_cards->{'notes'} and length $norm_cards->{'notes'} > 0;
	$norm_cards->{'notes'} .= join ': ', @$_;
    }

    return $norm_cards;
}

sub find_card_type {
    my $hr = shift;
    my $type = ($hr->{'url'} ne '' or $hr->{'username'} ne '' or $hr->{'password'} ne '') ? 'login' : 'note';
    debug "type detected as '$type'";
    return $type;
}

1;
