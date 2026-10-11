defmodule Apiary.Mail.TLS do
  @moduledoc """
  How mail is sent over TLS: the options `Swoosh.Adapters.SMTP` passes to `gen_smtp`, for
  both sources of mail, the saved settings (`Apiary.Mail.smtp_config/2`) and the
  environment's (`config/runtime.exs`, which calls `smtp_options/2`).

  The relay's certificate is checked: against the operating system's certificate
  authorities (`:public_key.cacerts_get/0`), and against the relay's name, as HTTPS
  checks a host. Only TLS 1.2 and 1.3 are offered. A relay that is a host name is the
  host connected to, never one of its MX records, and is sent as the TLS server name. A
  relay that is an IP address sends no server name, which names only hosts, and its
  certificate must name that address (`verify_ip/3`).

  `gen_smtp` reads `tls_options` when it upgrades a connection with STARTTLS, and
  `sockopts` when it connects with TLS from the start, on port 465; `sockopts` are also
  its plain connection's options, so they are given only for the latter.
  """

  # gen_smtp asks for a depth of 0 unless told otherwise, which only a certificate its
  # authority signed itself passes; this is OTP's own default.
  @depth 10

  @doc """
  smtp_options/2 is what the mailer's configuration for `relay` adds: `no_mx_lookups`, and
  the TLS options (`ssl_options/1`), as `sockopts` where `implicit_tls` (port 465), else
  as `tls_options`, for STARTTLS.
  """
  @spec smtp_options(String.t(), boolean) :: keyword
  def smtp_options(relay, implicit_tls) when is_binary(relay) and is_boolean(implicit_tls) do
    key = if implicit_tls, do: :sockopts, else: :tls_options
    [{:no_mx_lookups, true}, {key, ssl_options(relay)}]
  end

  @doc """
  ssl_options/1 is the options of `:ssl` for a connection to `relay`: the peer's
  certificate verified against the operating system's authorities, TLS 1.2 or 1.3, and the
  name checked: a host name as HTTPS does, sent as the server name; an IP address by
  `verify_ip/3`, with no server name sent.
  """
  @spec ssl_options(String.t()) :: keyword
  def ssl_options(relay) when is_binary(relay) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: @depth,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ] ++ identity(relay)
  end

  defp identity(relay) do
    case :inet.parse_strict_address(String.to_charlist(relay)) do
      {:ok, ip} ->
        [server_name_indication: :disable, verify_fun: {&__MODULE__.verify_ip/3, ip}]

      {:error, _not_an_address} ->
        [
          server_name_indication: String.to_charlist(relay),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
    end
  end

  @doc """
  verify_ip/3 is the `verify_fun` of `:ssl` for a relay that is the IP address `ip`: as
  OTP's own, it fails every certificate the path validation fails and every unknown
  extension, and it passes the relay's certificate only where that names `ip`. `:ssl`
  checks no name itself where no server name is sent.
  """
  @spec verify_ip(term, term, :inet.ip_address()) ::
          {:valid, :inet.ip_address()}
          | {:unknown, :inet.ip_address()}
          | {:fail, term}
  def verify_ip(_cert, {:bad_cert, _reason} = failure, _ip), do: {:fail, failure}
  def verify_ip(_cert, {:extension, _extension}, ip), do: {:unknown, ip}
  def verify_ip(_cert, :valid, ip), do: {:valid, ip}

  def verify_ip(cert, :valid_peer, ip) do
    if :public_key.pkix_verify_hostname(cert, ip: ip),
      do: {:valid, ip},
      else: {:fail, {:bad_cert, :hostname_check_failed}}
  end

  def verify_ip(_cert, other, _ip), do: {:fail, other}
end
