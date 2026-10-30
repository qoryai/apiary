defmodule Apiary.Adapters.CallTrust do
  # The certificate authorities an adapter call (`Apiary.Adapters.Calls`) trusts.
  #
  # With `SSL_CERT_FILE` unset or blank, a call sets no `cacerts`, and Mint takes the
  # operating system's (`:public_key.cacerts_get/0`). With it set, a call trusts the
  # operating system's authorities and every certificate in that PEM file, for a reverse
  # proxy whose certificate a private certificate authority signed. Either way Mint
  # verifies the peer (`verify: :verify_peer`) and checks the certificate against the
  # adapter's host.
  #
  # `config/runtime.exs` keeps the variable as `:ssl_cert_file_setting`, outside the
  # tests. `boot!/0` reads the file once, at boot, with the `factory` feature, and stops
  # a boot when the file cannot be read or has no certificate. It builds the list of
  # authorities once too and keeps it in `:persistent_term`, so every call passes the
  # same term: the connect options are part of the key of Req's Finch pool, which stays
  # one pool.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Features

  @key {__MODULE__, :transport_opts}

  @doc false
  # boot!/0 reads `SSL_CERT_FILE`'s file, with the `factory` feature, and keeps
  # `transport_opts/1` of its certificates for `transport_opts/0`; raises when the file
  # cannot be read or has no certificate.
  @spec boot!() :: :ok
  def boot! do
    certificates =
      case {Features.on?(:factory), Application.get_env(:apiary, :ssl_cert_file_setting)} do
        {true, path} when is_binary(path) and path != "" -> load!(path)
        _off_or_unset -> []
      end

    :persistent_term.put(@key, transport_opts(certificates))
    :ok
  end

  @doc false
  # load!/1 is the DER certificates of the PEM file at `path`, in order; raises when the
  # file cannot be read, has no certificate, or has a certificate that does not decode.
  @spec load!(String.t()) :: [binary]
  def load!(path) do
    case load(path) do
      {:ok, certificates} ->
        certificates

      {:error, cause} ->
        raise ArgumentError, """
        Set SSL_CERT_FILE to a PEM file of CA certificates, or unset it. #{cause}
        Adapter calls trust the operating system's certificate authorities and every \
        certificate in that file.
        """
    end
  end

  defp load(path) do
    with {:ok, pem} <- read(path),
         {:ok, [_ | _] = ders} <- certificates(pem, path) do
      {:ok, ders}
    else
      {:ok, []} -> {:error, "#{path} contains no PEM certificate."}
      {:error, _cause} = error -> error
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, pem} -> {:ok, pem}
      {:error, reason} -> {:error, "Reading #{path} failed: #{:file.format_error(reason)}."}
    end
  end

  # Only the CERTIFICATE blocks count, as Mint reads a `cacertfile`; each must decode.
  defp certificates(pem, path) do
    ders = for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
    Enum.each(ders, &:public_key.pkix_decode_cert(&1, :otp))
    {:ok, ders}
  rescue
    _malformed ->
      {:error, "#{path} contains a PEM block that is not a valid X.509 certificate."}
  end

  @doc false
  # transport_opts/0 is what a call adds to Mint's TLS options, as `boot!/0` kept it;
  # nothing before `boot!/0` ran.
  @spec transport_opts() :: keyword
  def transport_opts, do: :persistent_term.get(@key, [])

  @doc false
  # transport_opts/1 is what a call adds to Mint's TLS options: nothing without
  # certificates from `SSL_CERT_FILE`, so Mint takes the operating system's; with them,
  # `cacerts`, the operating system's then the file's. Where the operating system's store
  # cannot be read, the list has the file's alone.
  @spec transport_opts([binary]) :: keyword
  def transport_opts([]), do: []
  def transport_opts(certificates), do: [cacerts: system() ++ certificates]

  defp system do
    for {:cert, der, _otp} <- :public_key.cacerts_get(), do: der
  rescue
    _no_store -> []
  end
end
