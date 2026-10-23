defmodule Apiary.Registry.Token do
  @moduledoc false

  # A registry token, with the `registry` feature, which the documentation leaves out: a
  # JWT signed with ES256 under the registry signing key (`Apiary.Registry`), which the
  # registry checks against the key's certificate and never with a call to Qory Apiary.
  #
  # The header is `{"alg":"ES256","typ":"JWT","kid":…}`, `kid` the first 8 bytes of the
  # SHA-256 of the key's SubjectPublicKeyInfo in hex. The claims are `iss`, the instance's
  # public URL; `aud`, the registry's `QORY_REGISTRY`; `sub`, the run's public id; `exp`,
  # 15 minutes after the time of issue, always set, since the registry takes a token
  # without `exp` as one that never expires; `jti`, 16 random bytes in hex; and `access`,
  # the entries granted (`Apiary.Registry.Grant`). The registry checks neither `iss` nor
  # `aud`, nor `jti`, so a token stays valid until `exp`, also after its run ends.

  alias Apiary.Registry

  @lifetime_seconds 900

  @doc false
  @spec lifetime_seconds() :: pos_integer
  def lifetime_seconds, do: @lifetime_seconds

  @doc false
  # issue/4 is the JWT for the run `subject` with `access`, issued at `now`.
  @spec issue(String.t(), String.t(), [map], DateTime.t()) :: String.t()
  def issue(issuer, subject, access, %DateTime{} = now) do
    %{key: key, kid: kid, service: service} = Registry.settings()

    header = Jason.OrderedObject.new([{"alg", "ES256"}, {"typ", "JWT"}, {"kid", kid}])

    claims =
      Jason.OrderedObject.new([
        {"iss", issuer},
        {"aud", service},
        {"sub", subject},
        {"exp", DateTime.to_unix(now) + @lifetime_seconds},
        {"jti", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)},
        {"access", Enum.map(access, &entry/1)}
      ])

    input = encode(Jason.encode!(header)) <> "." <> encode(Jason.encode!(claims))
    input <> "." <> encode(signature(input, key))
  end

  defp entry(%{type: type, name: name, actions: actions}),
    do: Jason.OrderedObject.new([{"type", type}, {"name", name}, {"actions", actions}])

  # JWS ES256: r and s of the ECDSA signature over SHA-256, each 32 bytes big-endian
  # (RFC 7518, section 3.4).
  defp signature(input, key) do
    {:"ECDSA-Sig-Value", r, s} =
      :public_key.der_decode(:"ECDSA-Sig-Value", :public_key.sign(input, :sha256, key))

    <<r::unsigned-big-256, s::unsigned-big-256>>
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
