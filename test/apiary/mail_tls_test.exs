defmodule Apiary.MailTLSTest do
  @moduledoc """
  How mail is sent over TLS (`Apiary.Mail.TLS`): the options both sources of mail give
  `gen_smtp`, and the check of a relay given as an IP address. No connection is opened:
  the certificates are made here (`:public_key.pkix_test_data/1`).
  """
  use ExUnit.Case, async: true

  alias Apiary.Mail.TLS

  @ip {192, 0, 2, 10}

  # A certificate that names `addresses`, by IP, and no host.
  defp certificate(addresses) do
    names = for {a, b, c, d} <- addresses, do: {:iPAddress, <<a, b, c, d>>}
    san = {:Extension, {2, 5, 29, 17}, false, names}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [], intermediates: [], peer: [extensions: [san]]},
        client_chain: %{root: [], intermediates: [], peer: []}
      })

    :public_key.pkix_decode_cert(data[:server_config][:cert], :otp)
  end

  test "STARTTLS takes tls_options, TLS from the start sockopts, and neither looks up MX records" do
    assert [no_mx_lookups: true, tls_options: options] =
             TLS.smtp_options("smtp.example.com", false)

    assert options == TLS.ssl_options("smtp.example.com")

    assert [no_mx_lookups: true, sockopts: ^options] =
             TLS.smtp_options("smtp.example.com", true)
  end

  test "a host name is verified as HTTPS verifies one, and sent as the server name" do
    options = TLS.ssl_options("smtp.example.com")

    assert options[:verify] == :verify_peer
    assert [_ | _] = options[:cacerts]
    assert options[:depth] == 10
    assert options[:versions] == [:"tlsv1.2", :"tlsv1.3"]
    assert options[:server_name_indication] == ~c"smtp.example.com"
    assert [match_fun: match_fun] = options[:customize_hostname_check]
    assert is_function(match_fun, 2)
    refute Keyword.has_key?(options, :verify_fun)
  end

  test "an IP address is sent as no server name, and checked against the certificate" do
    options = TLS.ssl_options("192.0.2.10")

    assert options[:verify] == :verify_peer
    assert [_ | _] = options[:cacerts]
    assert options[:server_name_indication] == :disable
    assert options[:verify_fun] == {&TLS.verify_ip/3, @ip}
    refute Keyword.has_key?(options, :customize_hostname_check)
  end

  test "verify_ip/3 passes only a relay's certificate that names the address" do
    assert TLS.verify_ip(certificate([@ip]), :valid_peer, @ip) == {:valid, @ip}

    assert TLS.verify_ip(certificate([{192, 0, 2, 11}]), :valid_peer, @ip) ==
             {:fail, {:bad_cert, :hostname_check_failed}}

    assert TLS.verify_ip(certificate([]), :valid_peer, @ip) ==
             {:fail, {:bad_cert, :hostname_check_failed}}
  end

  test "verify_ip/3 fails what the path validation fails, as OTP's own does" do
    cert = certificate([@ip])

    assert TLS.verify_ip(cert, {:bad_cert, :unknown_ca}, @ip) ==
             {:fail, {:bad_cert, :unknown_ca}}

    assert TLS.verify_ip(cert, {:bad_cert, :cert_expired}, @ip) ==
             {:fail, {:bad_cert, :cert_expired}}

    assert TLS.verify_ip(cert, {:extension, :any}, @ip) == {:unknown, @ip}
    assert TLS.verify_ip(cert, :valid, @ip) == {:valid, @ip}
  end
end
