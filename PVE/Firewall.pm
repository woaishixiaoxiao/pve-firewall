package PVE::Firewall;

use warnings;
use strict;
use Data::Dumper;
use PVE::Tools;
use PVE::QemuServer;
use File::Path;
use IO::File;
use Net::IP;
use PVE::Tools qw(run_command lock_file);

use Data::Dumper;

my $pve_fw_lock_filename = "/var/lock/pvefw.lck";

my $macros;
my @ruleset = ();

# todo: implement some kind of MACROS, like shorewall /usr/share/shorewall/macro.*
sub get_firewall_macros {

    return $macros if $macros;

    #foreach my $path (</usr/share/shorewall/macro.*>) {
    #  if ($path =~ m|/macro\.(\S+)$|) {
    #    $macros->{$1} = 1;
    #  }
    #}

    $macros = {}; # fixme: implemet me

    return $macros;
}

my $etc_services;

sub get_etc_services {

    return $etc_services if $etc_services;

    my $filename = "/etc/services";

    my $fh = IO::File->new($filename, O_RDONLY);
    if (!$fh) {
	warn "unable to read '$filename' - $!\n";
	return {};
    }

    my $services = {};

    while (my $line = <$fh>) {
	chomp ($line);
	next if $line =~m/^#/;
	next if ($line =~m/^\s*$/);

	if ($line =~ m!^(\S+)\s+(\S+)/(tcp|udp).*$!) {
	    $services->{byid}->{$2}->{name} = $1;
	    $services->{byid}->{$2}->{$3} = 1;
	    $services->{byname}->{$1} = $services->{byid}->{$2};
	}
    }

    close($fh);

    $etc_services = $services;    
    

    return $etc_services;
}

my $etc_protocols;

sub get_etc_protocols {
    return $etc_protocols if $etc_protocols;

    my $filename = "/etc/protocols";

    my $fh = IO::File->new($filename, O_RDONLY);
    if (!$fh) {
	warn "unable to read '$filename' - $!\n";
	return {};
    }

    my $protocols = {};

    while (my $line = <$fh>) {
	chomp ($line);
	next if $line =~m/^#/;
	next if ($line =~m/^\s*$/);

	if ($line =~ m!^(\S+)\s+(\d+)\s+.*$!) {
	    $protocols->{byid}->{$2}->{name} = $1;
	    $protocols->{byname}->{$1} = $protocols->{byid}->{$2};
	}
    }

    close($fh);

    $etc_protocols = $protocols;

    return $etc_protocols;
}

sub parse_address_list {
    my ($str) = @_;

    my $nbaor = 0;
    foreach my $aor (split(/,/, $str)) {
	if (!Net::IP->new($aor)) {
	    my $err = Net::IP::Error();
	    die "invalid IP address: $err\n";
	}else{
	    $nbaor++;
	}
    }
    return $nbaor;
}

sub parse_port_name_number_or_range {
    my ($str) = @_;

    my $services = PVE::Firewall::get_etc_services();
    my $nbports = 0;
    foreach my $item (split(/,/, $str)) {
	my $portlist = "";
	foreach my $pon (split(':', $item, 2)) {
	    if ($pon =~ m/^\d+$/){
		die "invalid port '$pon'\n" if $pon < 0 && $pon > 65536;
	    }else{
		die "invalid port $services->{byname}->{$pon}\n" if !$services->{byname}->{$pon};
	    }
	    $nbports++;
	}
    }

    return ($nbports);
}

my $rule_format = "%-15s %-30s %-30s %-15s %-15s %-15s\n";

sub iptables {
    my ($cmd) = @_;

    run_command("/sbin/iptables $cmd", outfunc => sub {}, errfunc => sub {});
}

sub iptables_restore {

    unshift (@ruleset, '*filter');
    push (@ruleset, 'COMMIT');

    my $cmdlist = join("\n", @ruleset) . "\n";

    my $verbose = 1; # fixme: how/when do we set this

    #run_command("echo '$cmdlist' | /sbin/iptables-restore -n");
    eval { run_command("/sbin/iptables-restore -n ", input => $cmdlist); };
    if (my $err = $@) {
	print STDERR $cmdlist if $verbose;
	die $err;
    }
}

sub iptables_addrule {
   my ($rule) = @_;

   push (@ruleset, $rule);
}

sub iptables_chain_exist {
    my ($chain) = @_;

    eval{
	iptables("-n --list $chain");
    };
    return undef if $@;

    return 1;
}

sub iptables_rule_exist {
    my ($rule) = @_;

    eval{
	iptables("-C $rule");
    };
    return undef if $@;

    return 1;
}

sub iptables_generate_rule {
    my ($chain, $rule) = @_;

    my $cmd = "-A $chain";

    $cmd .= " -m iprange --src-range" if $rule->{nbsource} && $rule->{nbsource} > 1;
    $cmd .= " -s $rule->{source}" if $rule->{source};
    $cmd .= " -m iprange --dst-range" if $rule->{nbdest} && $rule->{nbdest} > 1;
    $cmd .= " -d $rule->{dest}" if $rule->{destination};
    $cmd .= " -p $rule->{proto}" if $rule->{proto};
    $cmd .= "  --match multiport" if $rule->{nbdport} && $rule->{nbdport} > 1;
    $cmd .= " --dport $rule->{dport}" if $rule->{dport};
    $cmd .= "  --match multiport" if $rule->{nbsport} && $rule->{nbsport} > 1;
    $cmd .= " --sport $rule->{sport}" if $rule->{sport};
    $cmd .= " -j $rule->{action}" if $rule->{action};

    iptables_addrule($cmd);

}

sub generate_bridge_rules {
    my ($bridge) = @_;

    if(!iptables_chain_exist("BRIDGEFW-OUT")){
	iptables_addrule(":BRIDGEFW-OUT - [0:0]");
    }

    if(!iptables_chain_exist("BRIDGEFW-IN")){
	iptables_addrule(":BRIDGEFW-IN - [0:0]");
    }

    if(!iptables_chain_exist("proxmoxfw-FORWARD")){
	iptables_addrule(":proxmoxfw-FORWARD - [0:0]");
	iptables_addrule("-I FORWARD -j proxmoxfw-FORWARD");
	iptables_addrule("-A proxmoxfw-FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT");
	iptables_addrule("-A proxmoxfw-FORWARD -m physdev --physdev-is-in --physdev-is-bridged -j BRIDGEFW-OUT");
	iptables_addrule("-A proxmoxfw-FORWARD -m physdev --physdev-is-out --physdev-is-bridged -j BRIDGEFW-IN");

    }

    generate_proxmoxfwinput();

    if(!iptables_chain_exist("$bridge-IN")){
	iptables_addrule(":$bridge-IN - [0:0]");
	iptables_addrule("-A proxmoxfw-FORWARD -i $bridge -j DROP");  #disable interbridge routing
	iptables_addrule("-A BRIDGEFW-IN -j $bridge-IN");
	iptables_addrule("-A $bridge-IN -j ACCEPT");

    }

    if(!iptables_chain_exist("$bridge-OUT")){
	iptables_addrule(":$bridge-OUT - [0:0]");
	iptables_addrule("-A proxmoxfw-FORWARD -o $bridge -j DROP"); # disable interbridge routing
	iptables_addrule("-A BRIDGEFW-OUT -j $bridge-OUT");

    }

}


sub generate_tap_rules_direction {
    my ($iface, $netid, $rules, $bridge, $direction) = @_;

    my $tapchain = "$iface-$direction";

    iptables_addrule(":$tapchain - [0:0]");

    iptables_addrule("-A $tapchain -m state --state INVALID -j DROP");
    iptables_addrule("-A $tapchain -m state --state RELATED,ESTABLISHED -j ACCEPT");

    if (scalar(@$rules)) {
        foreach my $rule (@$rules) {
	    next if $rule->{iface} && $rule->{iface} ne $netid;
	    if($rule->{action}  =~ m/^(GROUP-(\S+))$/){
		    $rule->{action} .= "-$direction";
		    #generate empty group rule if don't exist
		    if(!iptables_chain_exist($rule->{action})){
			generate_group_rules($2);
		    }
	    }
	    #we go to vmbr-IN if accept in out rules
	    $rule->{action} = "$bridge-IN" if $rule->{action} eq 'ACCEPT' && $direction eq 'OUT';
	    iptables_generate_rule($tapchain, $rule);
        }
    }

    iptables_addrule("-A $tapchain -j LOG --log-prefix \"$tapchain-dropped: \" --log-level 4");
    iptables_addrule("-A $tapchain -j DROP");

    #plug the tap chain to bridge chain
    my $physdevdirection = $direction eq 'IN' ? "out":"in";
    my $rule = "$bridge-$direction -m physdev --physdev-$physdevdirection $iface --physdev-is-bridged -j $tapchain";

    if(!iptables_rule_exist($rule)){
	iptables_addrule("-I $rule");
    }

    if($direction eq 'OUT'){
	#add tap->host rules
	my $rule = "proxmoxfw-INPUT -m physdev --physdev-$physdevdirection $iface -j $tapchain";

	if(!iptables_rule_exist($rule)){
	    iptables_addrule("-A $rule");
	}
    }
}

sub generate_tap_rules {
    my ($net, $netid, $vmid) = @_;

    my $filename = "/etc/pve/firewall/$vmid.fw";
    my $fh = IO::File->new($filename, O_RDONLY);
    return if !$fh;

    #generate bridge rules
    my $bridge = $net->{bridge};
    my $tag = $net->{tag};
    $bridge .= "v$tag" if $tag;
   
    #generate tap chain
    my $rules = parse_fw_rules($filename, $fh);

    my $inrules = $rules->{in};
    my $outrules = $rules->{out};

    my $iface = "tap".$vmid."i".$1 if $netid =~ m/net(\d+)/;

    generate_bridge_rules($bridge);
    generate_tap_rules_direction($iface, $netid, $inrules, $bridge, 'IN');
    generate_tap_rules_direction($iface, $netid, $outrules, $bridge, 'OUT');
    iptables_restore();
}

sub flush_tap_rules {
    my ($net, $netid, $vmid) = @_;

    my $bridge = $net->{bridge};
    my $iface = "tap".$vmid."i".$1 if $netid =~ m/net(\d+)/;

    flush_tap_rules_direction($iface, $bridge, 'IN');
    flush_tap_rules_direction($iface, $bridge, 'OUT');
    iptables_restore();
}

sub flush_tap_rules_direction {
    my ($iface, $bridge, $direction) = @_;

    my $tapchain = "$iface-$direction";

    if(iptables_chain_exist($tapchain)){
	iptables_addrule("-F $tapchain");

	my $physdevdirection = $direction eq 'IN' ? "out":"in";
	my $rule = "$bridge-$direction -m physdev --physdev-$physdevdirection $iface --physdev-is-bridged -j $tapchain";
	if(iptables_rule_exist($rule)){
	    iptables_addrule("-D $rule");
	}

	if($direction eq 'OUT'){
	    my $rule = "proxmoxfw-INPUT -m physdev --physdev-$physdevdirection $iface -j $tapchain";
	    if(iptables_rule_exist($rule)){
		iptables_addrule("-D $rule");
	    }
	}

	iptables_addrule("-X $tapchain");
    }
}

sub enablehostfw {

    generate_proxmoxfwinput();
    generate_proxmoxfwoutput();

    my $filename = "/etc/pve/local/host.fw";
    my $fh = IO::File->new($filename, O_RDONLY);
    return if !$fh;

    my $rules = parse_fw_rules($filename, $fh);
    my $inrules = $rules->{in};
    my $outrules = $rules->{out};

    #host inbound firewall
    iptables_addrule(":host-IN - [0:0]");
    iptables_addrule("-A host-IN -m state --state INVALID -j DROP");
    iptables_addrule("-A host-IN -m state --state RELATED,ESTABLISHED -j ACCEPT");
    iptables_addrule("-A host-IN -i lo -j ACCEPT");
    iptables_addrule("-A host-IN -m addrtype --dst-type MULTICAST -j ACCEPT");
    iptables_addrule("-A host-IN -p udp -m state --state NEW -m multiport --dports 5404,5405 -j ACCEPT");
    iptables_addrule("-A host-IN -p udp -m udp --dport 9000 -j ACCEPT"); #corosync

    if (scalar(@$inrules)) {
        foreach my $rule (@$inrules) {
            #we use RETURN because we need to check also tap rules
            $rule->{action} = 'RETURN' if $rule->{action} eq 'ACCEPT';
            iptables_generate_rule('host-IN', $rule);
        }
    }

    iptables_addrule("-A host-IN -j LOG --log-prefix \"kvmhost-IN dropped: \" --log-level 4");
    iptables_addrule("-A host-IN -j DROP");

    #host outbound firewall
    iptables_addrule(":host-OUT - [0:0]");
    iptables_addrule("-A host-OUT -m state --state INVALID -j DROP");
    iptables_addrule("-A host-OUT -m state --state RELATED,ESTABLISHED -j ACCEPT");
    iptables_addrule("-A host-OUT -o lo -j ACCEPT");
    iptables_addrule("-A host-OUT -m addrtype --dst-type MULTICAST -j ACCEPT");
    iptables_addrule("-A host-OUT -p udp -m state --state NEW -m multiport --dports 5404,5405 -j ACCEPT");
    iptables_addrule("-A host-OUT -p udp -m udp --dport 9000 -j ACCEPT"); #corosync

    if (scalar(@$outrules)) {
        foreach my $rule (@$outrules) {
            #we use RETURN because we need to check also tap rules
            $rule->{action} = 'RETURN' if $rule->{action} eq 'ACCEPT';
            iptables_generate_rule('host-OUT', $rule);
        }
    }

    iptables_addrule("-A host-OUT -j LOG --log-prefix \"kvmhost-OUT dropped: \" --log-level 4");
    iptables_addrule("-A host-OUT -j DROP");

    
    my $rule = "proxmoxfw-INPUT -j host-IN";
    if(!iptables_rule_exist($rule)){
	iptables_addrule("-I $rule");
    }

    $rule = "proxmoxfw-OUTPUT -j host-OUT";
    if(!iptables_rule_exist($rule)){
	iptables_addrule("-I $rule");
    }

    iptables_restore();


}

sub disablehostfw {

    my $chain = "host-IN";

    my $rule = "proxmoxfw-INPUT -j $chain";
    if(iptables_rule_exist($rule)){
	iptables_addrule("-D $rule");
    }

    if(iptables_chain_exist($chain)){
	iptables_addrule("-F $chain");
	iptables_addrule("-X $chain");
    }

    $chain = "host-OUT";

    $rule = "proxmoxfw-OUTPUT -j $chain";
    if(iptables_rule_exist($rule)){
	iptables_addrule("-D $rule");
    }

    if(iptables_chain_exist($chain)){
	iptables_addrule("-F $chain");
	iptables_addrule("-X $chain");
    }

    iptables_restore();   
}

sub generate_proxmoxfwinput {

    if(!iptables_chain_exist("proxmoxfw-INPUT")){
        iptables_addrule(":proxmoxfw-INPUT - [0:0]");
        iptables_addrule("-I INPUT -j proxmoxfw-INPUT");
        iptables_addrule("-A INPUT -j ACCEPT");
    }
}

sub generate_proxmoxfwoutput {

    if(!iptables_chain_exist("proxmoxfw-OUTPUT")){
        iptables_addrule(":proxmoxfw-OUTPUT - [0:0]");
        iptables_addrule("-I OUTPUT -j proxmoxfw-OUTPUT");
        iptables_addrule("-A OUTPUT -j ACCEPT");
    }

}

sub enable_group_rules {
    my ($group) = @_;
    
    generate_group_rules($group);
    iptables_restore();
}

sub generate_group_rules {
    my ($group) = @_;

    my $filename = "/etc/pve/firewall/groups.fw";
    my $fh = IO::File->new($filename, O_RDONLY);
    return if !$fh;

    my $rules = parse_fw_rules($filename, $fh, $group);
    my $inrules = $rules->{in};
    my $outrules = $rules->{out};

    my $chain = "GROUP-".$group."-IN";

    iptables_addrule(":$chain - [0:0]");

    if (scalar(@$inrules)) {
        foreach my $rule (@$inrules) {
            iptables_generate_rule($chain, $rule);
        }
    }

    $chain = "GROUP-".$group."-OUT";

    iptables_addrule(":$chain - [0:0]");

    if(!iptables_chain_exist("BRIDGEFW-OUT")){
	iptables_addrule(":BRIDGEFW-OUT - [0:0]");
    }

    if(!iptables_chain_exist("BRIDGEFW-IN")){
	iptables_addrule(":BRIDGEFW-IN - [0:0]");
    }

    if (scalar(@$outrules)) {
        foreach my $rule (@$outrules) {
            #we go the BRIDGEFW-IN because we need to check also other tap rules 
            #(and group rules can be set on any bridge, so we can't go to VMBRXX-IN)
            $rule->{action} = 'BRIDGEFW-IN' if $rule->{action} eq 'ACCEPT';
            iptables_generate_rule($chain, $rule);
        }
    }

}

sub disable_group_rules {
    my ($group) = @_;

    my $chain = "GROUP-".$group."-IN";

    if(iptables_chain_exist($chain)){
	iptables_addrule("-F $chain");
	iptables_addrule("-X $chain");
    }

    $chain = "GROUP-".$group."-OUT";

    if(iptables_chain_exist($chain)){
	iptables_addrule("-F $chain");
	iptables_addrule("-X $chain");
    }

    #iptables_restore will die if security group is linked in a tap chain
    #maybe can we improve that, parsing each vm config, or parsing iptables -S
    #to see if the security group is linked or not
    iptables_restore();
}

sub parse_fw_rules {
    my ($filename, $fh, $group) = @_;

    my $section;
    my $securitygroup;
    my $securitygroupexist;

    my $res = { in => [], out => [] };

    my $macros = get_firewall_macros();
    my $protocols = get_etc_protocols();
    
    while (defined(my $line = <$fh>)) {
	next if $line =~ m/^#/;
	next if $line =~ m/^\s*$/;

	if ($line =~ m/^\[(in|out)(:(\S+))?\]\s*$/i) {
	    $section = lc($1);
	    $securitygroup = lc($3) if $3;
	    $securitygroupexist = 1 if $securitygroup &&  $securitygroup eq $group;
	    next;
	}
	next if !$section;
	next if $group && $securitygroup ne $group;

	my ($action, $iface, $source, $dest, $proto, $dport, $sport) =
	    split(/\s+/, $line);

	if (!$action) {
	    warn "skip incomplete line\n";
	    next;
	}

	my $service;
	if ($action =~ m/^(ACCEPT|DROP|REJECT|GROUP-(\S+))$/) {
	    # OK
	} elsif ($action =~ m/^(\S+)\((ACCEPT|DROP|REJECT)\)$/) {
	    ($service, $action) = ($1, $2);
	    if (!$macros->{$service}) {
		warn "unknown service '$service'\n";
		next;
	    }
	} else {
	    warn "unknown action '$action'\n";
	    next;
	}

	$iface = undef if $iface && $iface eq '-';
	if ($iface && $iface !~ m/^(net0|net1|net2|net3|net4|net5)$/) {
	    warn "unknown interface '$iface'\n";
	    next;
	}

	$proto = undef if $proto && $proto eq '-';
	if ($proto && !(defined($protocols->{byname}->{$proto}) ||
			defined($protocols->{byid}->{$proto}))) {
	    warn "unknown protokol '$proto'\n";
	    next;
	}

	$source = undef if $source && $source eq '-';
	$dest = undef if $dest && $dest eq '-';

	$dport = undef if $dport && $dport eq '-';
	$sport = undef if $sport && $sport eq '-';
	my $nbdport = undef;
	my $nbsport = undef;
	my $nbsource = undef;
	my $nbdest = undef;

	eval {
	    $nbsource = parse_address_list($source) if $source;
	    $nbdest = parse_address_list($dest) if $dest;
	    $nbdport = parse_port_name_number_or_range($dport) if $dport;
	    $nbsport = parse_port_name_number_or_range($sport) if $sport;
	};
	if (my $err = $@) {
	    warn $err;
	    next;

	}


	my $rule = {
	    action => $action,
	    service => $service,
	    iface => $iface,
	    source => $source,
	    dest => $dest,
	    nbsource => $nbsource,
	    nbdest => $nbdest,
	    proto => $proto,
	    dport => $dport,
	    sport => $sport,
	    nbdport => $nbdport,
	    nbsport => $nbsport,

	};

	push @{$res->{$section}}, $rule;
    }

    die "security group $group don't exist" if $group && !$securitygroupexist;
    return $res;
}

sub run_locked {
    my ($code, @param) = @_;

    my $timeout = 10;

    my $res = lock_file($pve_fw_lock_filename, $timeout, $code, @param);

    die $@ if $@;

    return $res;
}

sub read_local_vm_config {

    my $openvz = {};

    my $qemu = {};

    my $list = PVE::QemuServer::config_list();

    foreach my $vmid (keys %$list) {
	#next if !($vmid eq '100' || $vmid eq '102');
	my $cfspath = PVE::QemuServer::cfs_config_path($vmid);
	if (my $conf = PVE::Cluster::cfs_read_file($cfspath)) {
	    $qemu->{$vmid} = $conf;
	}
    }

    my $vmdata = { openvz => $openvz, qemu => $qemu };

    return $vmdata;
};

sub read_vm_firewall_rules {
    my ($vmdata) = @_;
    my $rules = {};
    foreach my $vmid (keys %{$vmdata->{qemu}}, keys %{$vmdata->{openvz}}) {
	my $filename = "/etc/pve/firewall/$vmid.fw";
	my $fh = IO::File->new($filename, O_RDONLY);
	next if !$fh;

	$rules->{$vmid} = parse_fw_rules($filename, $fh);
    }

    return $rules;
}

sub compile {
    my $vmdata = read_local_vm_config();
    my $rules = read_vm_firewall_rules($vmdata);

    # print Dumper($vmdata);

    die "implement me";
}

sub compile_and_start {
    my ($restart) = @_;

    compile();

     die "implement me";  
}

1;
