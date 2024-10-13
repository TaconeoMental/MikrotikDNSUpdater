:global logPrefix "[DHCP2DNS]"
:global dnsUpdater "http://<updater-host>:5000"
:local isDebug 1
:local networkDomain
:local dnsSuffix
:local ttl

:global logDebug do={
     :log info ($logPrefix . " " . $1)
}

:global updateRemoteRecord do={
    :local endpoint ($dnsUpdater . "/update/" . $1 . "/" . $2)
    $logDebug $endpoint
    /tool fetch url=$endpoint keep-result=no
}

:global deleteRemoteRecord do={
    :local endpoint ($dnsUpdater . "/delete/" . $1)
    $logDebug $endpoint
    /tool fetch url=$endpoint keep-result=no
}

:local cleanHostname do={
    :local max ([:len $1] - 1);
    :if ($1 ~ "^[a-zA-Z0-9]+[a-zA-Z0-9\\-]*[a-zA-Z0-9]+\$" && ([:pick $1 ($max)] != "\00")) do={
        :return ($1);
    } else={
        :local cleaned "";
        :for i from=0 to=$max do={
            :local c [:pick $1 $i]
            :if ($c ~ "^[a-zA-Z0-9]{1}\$") do={
                :set cleaned ($cleaned . $c)
            } else={
                if ($c = "-" and $i > 0 and $i < $max) do={
                    :set cleaned ($cleaned . $c)
                }
            }
        }
    :return ($cleaned);
    }
}

/ip dhcp-server network
:set networkDomain [get [find $leaseActIP in address] domain]

:if ([:len $networkDomain] <= 0) do={
    $logDebug "No network domain."
    :error "Omitting..."
}
:set dnsSuffix ("." . $networkDomain)

:if ([:len $"lease-hostname"] <= 0) do={
    $logDebug "Empty hostname"
    :error "Omitting..."
}

:if ($leaseBound = "1") do={
    $logDebug ($"lease-hostname"." is requesting an IP from " . $leaseServerName)
} else={
    $logDebug ($"lease-hostname"." is releasing its IP from " . $leaseServerName)
}

/ip dhcp-server
:set ttl [get [find name=$leaseServerName] lease-time]

# Asumo que aquí ya va todo bien
:local dhcpLeases;
:set $dhcpLeases [:toarray ""]
/ip dhcp-server lease
:foreach lease in=[find where server=$leaseServerName] do={
  :local hostRaw [get $lease host-name]
  :if ([:len $hostRaw] > 0) do={
    :local hostCleaned
    :set hostCleaned [$cleanHostname $hostRaw]
    :set ($dhcpLeases->$hostCleaned) $lease
  }
}

/ip dns static
:foreach record in=[find where comment="<AUTO:DHCP:$leaseServerName>"] do={
  :local fqdn [get $record name]
  :local hostname [:pick $fqdn 0 ([:len $fqdn] - [:len $dnsSuffix])]
  :local leaseMatch ($dhcpLeases->$hostname)
  
  :if ([:len $leaseMatch] < 1) do={
    $logDebug ("Removing stale DNS record '$fqdn'")
    $deleteRemoteRecord $hostname
    remove $record
  } else={
    :local lease [/ip dhcp-server lease get $leaseMatch address]
    :if ($lease != [get $record address]) do={
      $logDebug ("Updating stale DNS record '$fqdn' to $lease")
      :do {
        set $record address=$lease
        $updateRemoteRecord $hostname $lease
      } on-error={
        :log warning ("Unable to update stale DNS record '$fqdn'")
      }
    }
  }
}

/ip dns static
:foreach k,v in=$dhcpLeases do={
  :local fqdn ($k . $dnsSuffix)
  :if ([:len [find where name=$fqdn]] < 1) do={
    :local lease [/ip dhcp-server lease get $v address]
    $logDebug ("Creating DNS record '$fqdn': $lease")
    :do {
      add name=$fqdn address=$lease ttl=$ttl comment="<AUTO:DHCP:$leaseServerName>"
      $updateRemoteRecord $k $lease
    } on-error={
      :log warning "Unable to create DNS record '$fqdn'"
    }
  }
}
