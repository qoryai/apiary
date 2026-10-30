defmodule Apiary.Registry do
  @moduledoc false

  # With the `registry` feature, which the documentation leaves out: the instance's
  # setting for the private image registry and the key it signs registry tokens with.
  #
  # `QORY_REGISTRY` is the registry's address: a lower-case host, a DNS name or an IPv4
  # address, and an optional port, `registry.qory.example` or `registry.qory.example:5000`.
  # It is the token's `aud`, the `service` a token request must have (`service/0`), and
  # its host is the host the run configuration's path rules are for (`host/0`).
  #
  # The signing key is an ECDSA P-256 key used for registry tokens alone, in PEM, in
  # `registry-token.key` of `APIARY_KEYS_DIR`, which `bin/keys` writes when
  # `QORY_REGISTRY` is set (`rel/overlays/bin/keys`). `bin/keys` also writes the key's
  # certificate, `registry-token.crt`, to `APIARY_REGISTRY_CERT_DIR`, a directory on a
  # volume the registry mounts read-only, through a temporary file and a rename. The
  # registry reads the certificate only when it starts and holds exactly one, so after a
  # rotation (delete the key, run `bin/keys` again, restart Qory Apiary) the registry
  # restarts too: a token signed under the old key fails at the registry from the moment
  # the registry reads the new certificate, and a token signed under the new key fails
  # until then.
  #
  # `boot!/0` checks both when the feature is on, and stops the boot with the fix first:
  # a missing or malformed `QORY_REGISTRY`, one whose host is the host of `PUBLIC_URL`
  # (compared without case and without ports), and a key file that is missing or holds
  # no P-256 key. The host must differ because a run's path rules are per host: the
  # registry's rules and the instance's `/registry/token` would otherwise apply to one
  # host. The key's value is never logged and never in an exception.
  #
  # In test, `config :apiary, Apiary.Registry, generate_key: true` makes a key once per
  # node, in memory: the application boots there before the suite turns the opt-in
  # features on, so `settings/0` reads the setting and the key when first asked.

  alias Apiary.Features

  @curve {1, 2, 840, 10045, 3, 1, 7}

  @host_label "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
  @host ~r/\A((#{@host_label}\.)*[a-z]([a-z0-9-]{0,61}[a-z0-9])?|(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3})(:([1-9][0-9]{0,4}))?\z/

  @default_key_file "/var/lib/apiary/keys/registry-token.key"

  @typedoc "The registry's address, its host, and the signing key."
  @type settings :: %{
          service: String.t(),
          host: String.t(),
          key: tuple,
          public_der: binary,
          kid: String.t()
        }

  @doc false
  # boot!/0 checks `QORY_REGISTRY` and the signing key when the feature `registry` is on,
  # and keeps them for the life of the node. Raises `ArgumentError` with the fix first.
  @spec boot!() :: :ok
  def boot! do
    if Features.on?(:registry) do
      Application.put_env(:apiary, __MODULE__.Settings, read!())
    end

    :ok
  end

  @doc false
  # settings/0 is the registry's settings: kept by `boot!/0`, else read now.
  @spec settings() :: settings
  def settings do
    case Application.fetch_env(:apiary, __MODULE__.Settings) do
      {:ok, settings} ->
        settings

      :error ->
        settings = read!()
        Application.put_env(:apiary, __MODULE__.Settings, settings)
        settings
    end
  end

  @doc false
  # configured?/0 is whether the instance has a registry its prebuilds push to: the
  # feature on, and `QORY_REGISTRY` set to an address an image name can start with. An
  # image name starts with a host that has a dot or a port, or is `localhost`: Docker
  # reads a first part without either as a path on Docker Hub. A read of the node's
  # settings alone, with no query: every claim, hold and page read asks it. Without a
  # registry, no prebuild is queued or claimed (`Apiary.Environments`,
  # `Apiary.Dispatches`). The instance's registry name is made where a prebuild's
  # destinations are (`Apiary.InstanceConfig.registry_instance/0`).
  @spec configured?() :: boolean
  def configured? do
    Features.on?(:registry) and image_host?(Application.get_env(:apiary, :registry_setting))
  end

  defp image_host?(setting) do
    case parse(setting) do
      {:ok, %{service: service, host: host}} ->
        String.contains?(service, [".", ":"]) or host == "localhost"

      _unset_or_invalid ->
        false
    end
  end

  @doc false
  # service/0 is `QORY_REGISTRY` as set: the token's `aud`, and the `service` a token
  # request must have.
  @spec service() :: String.t()
  def service, do: settings().service

  @doc false
  # host/0 is the host of `QORY_REGISTRY`, without its port.
  @spec host() :: String.t()
  def host, do: settings().host

  @doc false
  # parse/1 reads a value of `QORY_REGISTRY`: `{:ok, %{service, host}}`, `:unset` for
  # nil or blank, `:error` for any other value.
  @spec parse(String.t() | nil) ::
          {:ok, %{service: String.t(), host: String.t()}} | :unset | :error
  def parse(nil), do: :unset

  def parse(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        :unset

      byte_size(value) <= 259 and Regex.match?(@host, value) and port_ok?(value) ->
        [host | _port] = String.split(value, ":")
        {:ok, %{service: value, host: host}}

      true ->
        :error
    end
  end

  defp port_ok?(value) do
    case String.split(value, ":") do
      [_host] -> true
      [_host, port] -> String.to_integer(port) in 1..65_535
    end
  end

  @doc false
  # key_file/0 is the path of the signing key's file.
  @spec key_file() :: String.t()
  def key_file,
    do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :key_file, @default_key_file)

  @doc false
  # decode_key/1 is the P-256 private key in `pem`: `{:ok, key}` or `:error`.
  @spec decode_key(binary) :: {:ok, tuple} | :error
  def decode_key(pem) when is_binary(pem) do
    with [entry | _] <- :public_key.pem_decode(pem),
         {:ECPrivateKey, _version, _private, {:namedCurve, @curve}, _public, _attributes} =
           key <- :public_key.pem_entry_decode(entry) do
      {:ok, key}
    else
      _other -> :error
    end
  rescue
    _exception -> :error
  end

  defp read! do
    setting = Application.get_env(:apiary, :registry_setting)

    address =
      case parse(setting) do
        {:ok, address} ->
          address

        :unset ->
          raise ArgumentError, """
          Set QORY_REGISTRY to the registry's host, for example QORY_REGISTRY=registry.qory.example.
          The feature registry is on in QORY_FEATURES, and QORY_REGISTRY is not set.
          """

        :error ->
          raise ArgumentError, """
          Set QORY_REGISTRY to a host and an optional port, with no scheme or path, for example registry.qory.example.
          QORY_REGISTRY is set to #{String.trim(setting)}.
          """
      end

    if same_host?(address.host, public_host()) do
      raise ArgumentError, """
      Set QORY_REGISTRY to a host other than #{address.host}.
      PUBLIC_URL uses the same host, and a run's egress rules work only when the registry and Qory Apiary are on separate hosts.
      """
    end

    Map.merge(address, with_public(key!()))
  end

  # The host of the instance's public URL as configured, `PUBLIC_URL`'s, nil for none.
  defp public_host do
    with config when is_list(config) <- Application.get_env(:apiary, ApiaryWeb.Endpoint),
         url when is_list(url) <- Keyword.get(config, :url),
         host when is_binary(host) <- Keyword.get(url, :host) do
      host
    else
      _none -> nil
    end
  end

  defp same_host?(_registry, nil), do: false

  defp same_host?(registry, public),
    do: String.downcase(registry) == public |> String.downcase() |> String.trim_trailing(".")

  defp key! do
    if Keyword.get(Application.get_env(:apiary, __MODULE__, []), :generate_key, false) do
      :public_key.generate_key({:namedCurve, @curve})
    else
      path = key_file()

      case File.read(path) do
        {:ok, pem} ->
          case decode_key(pem) do
            {:ok, key} ->
              key

            :error ->
              raise ArgumentError, """
              Delete #{path}, run bin/keys again, then restart the registry.
              The file is not a P-256 private key in PEM form.
              """
          end

        {:error, :enoent} ->
          raise ArgumentError, """
          Run bin/keys with QORY_REGISTRY set, so it writes the registry signing key to #{path}.
          The feature registry is on, and that file does not exist.
          """

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read file", path: path
      end
    end
  end

  # The key with its public half as the registry's certificate has it, DER of the
  # SubjectPublicKeyInfo, and `kid`, the first 8 bytes of its SHA-256 in hex.
  defp with_public({:ECPrivateKey, _version, _private, params, point, _attributes} = key) do
    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, point}, params})

    kid = :crypto.hash(:sha256, der) |> binary_part(0, 8) |> Base.encode16(case: :lower)
    %{key: key, public_der: der, kid: kid}
  end
end
