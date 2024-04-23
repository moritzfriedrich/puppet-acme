# @summary Create a Certificate Signing Request (CSR) and send it to PuppetDB
#
# @param acme_host
#   Host the certificate will be signed on.
#
# @param ca
#   The ACME CA that should be used. Used to overwrite the default
#   CA that is configured on `$acme_host`.
#
# @param use_account
#   The ACME account that should be used (or registered).
#   This account must exist in `$accounts` on your `$acme_host`.
#
# @param use_profile
#   The profile that should be used to sign the certificate.
#   This profile must exist in `$profiles` on your `$acme_host`.
#
# @api private
define acme::csr (
  String $acme_host,
  String $use_account,
  String $use_profile,
  Array[String] $domains,
  Integer $dh_param_size = 2048,
  Enum['present','absent'] $ensure = 'present',
  Boolean $force = true,
  Boolean $ocsp_must_staple = true,
  Integer $renew_days = $acme::renew_days,
  Variant[Enum['buypass', 'buypass_test', 'letsencrypt', 'letsencrypt_test', 'sslcom', 'zerossl'],Stdlib::HTTPUrl,Undef] $ca = undef,
  Optional[String] $country = undef,
  Optional[String] $state = undef,
  Optional[String] $locality = undef,
  Optional[String] $organization = undef,
  Optional[String] $unit = undef,
  Optional[String] $email = undef,
  Optional[String] $password = undef,
) {
  $user = $acme::user
  $group = $acme::group

  $base_dir = $acme::base_dir
  $cfg_dir = $acme::cfg_dir
  $key_dir = $acme::key_dir
  $crt_dir = $acme::crt_dir
  $path = $acme::path
  $date_expression = $acme::date_expression
  $stat_expression = $acme::stat_expression

  # Handle certificates with multiple domain names (SAN).
  $domain = $domains[0]
  $has_san = size($domains) > 1
  if ($has_san) {
    $altnames = delete_at($domains, 0)
    $subject_alt_names = $domains
  } else {
    $altnames = []
    $subject_alt_names = []
  }

  file { "${cfg_dir}/${name}":
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    require => Group[$group],
  }

  file { "${key_dir}/${name}":
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0750',
    require => Group[$group],
  }

  ensure_resource('file', "${crt_dir}/${name}", {
      ensure  => directory,
      mode    => '0755',
      owner   => $user,
      group   => $group,
      require => [
        User[$user],
        Group[$group]
      ],
  })

  $cnf_file = "${cfg_dir}/${name}/ssl.cnf"
  $dh_file  = "${cfg_dir}/${name}/params.dh"
  $key_file = "${key_dir}/${name}/private.key"
  $csr_file = "${crt_dir}/${name}/cert.csr"
  $crt_file = "${crt_dir}/${name}/cert.pem"

  $create_dh_unless = join([
      'test',
      '-f',
      "\'${dh_file}\'",
      '&&',
      'test',
      '$(',
      "${stat_expression} \'${dh_file}\'",
      ')',
      '-gt',
      '$(',
      $date_expression,
      ')',
  ], ' ')

  exec { "create-dh-${dh_file}":
    require => [
      File[$crt_dir]
    ],
    user    => 'root',
    group   => $group,
    path    => $path,
    command => "openssl dhparam -check -out \'${dh_file}\' ${dh_param_size}",
    unless  => $create_dh_unless,
    timeout => 30*60,
  }

  file { $dh_file:
    ensure  => $ensure,
    owner   => 'root',
    group   => $group,
    mode    => '0644',
    require => Exec["create-dh-${dh_file}"],
  }

  file { $cnf_file:
    ensure  => $ensure,
    owner   => 'root',
    group   => $group,
    mode    => '0644',
    content => epp("${module_name}/cert.cnf.epp", {
        country           => $country,
        domain            => $domain,
        email             => $email,
        has_san           => $has_san,
        locality          => $locality,
        ocsp_must_staple  => $ocsp_must_staple,
        organization      => $organization,
        state             => $state,
        subject_alt_names => $subject_alt_names,
        unit              => $unit,
    }),
  }

  ssl_pkey { $key_file:
    ensure   => $ensure,
    password => $password,
    require  => File[$key_dir],
  }

  x509_request { $csr_file:
    ensure      => $ensure,
    template    => $cnf_file,
    private_key => $key_file,
    password    => $password,
    force       => $force,
    require     => File[$cnf_file],
  }

  exec { "refresh-csr-${csr_file}":
    path        => $path,
    command     => "rm -f \'${csr_file}\'",
    refreshonly => true,
    user        => 'root',
    group       => $group,
    before      => X509_request[$csr_file],
    subscribe   => File[$cnf_file],
  }

  file { $key_file:
    ensure  => $ensure,
    owner   => 'root',
    group   => $group,
    mode    => '0640',
    require => Ssl_pkey[$key_file],
  }

  file { $csr_file:
    ensure  => $ensure,
    owner   => 'root',
    group   => $group,
    mode    => '0644',
    require => X509_request[$csr_file],
  }

  $csr_content = pick_default($facts.dig('acme_csrs', $name), '')
  if ($csr_content =~ /CERTIFICATE REQUEST/) {
    @@acme::request { $name:
      csr              => $csr_content,
      tag              => "master_${acme_host}",
      domain           => $domain,
      altnames         => $altnames,
      use_account      => $use_account,
      use_profile      => $use_profile,
      renew_days       => $renew_days,
      ca               => $ca,
      ocsp_must_staple => $ocsp_must_staple,
    }
  } else {
    notify { "no CSR from facter for cert ${name} (normal on first run)" : }
  }
}
