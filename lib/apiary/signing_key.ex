defmodule Apiary.SigningKey do
  @moduledoc """
  The instance's own Ed25519 signing key: the key it signs its answers to runners with,
  and the key every machine pins as `apiary_public_key` (the runner contract's "Signed
  answers" and "The pin").

  **Where it comes from.** The key's seed is `APIARY_SIGNING_SECRET`, 32 random bytes in
  base64, read by `config/runtime.exs` in production, where it is required and has no
  fallback. `config/dev.exs` and `config/test.exs` set a fixed seed of their own. It is
  never derived from `APIARY_ENCRYPTION_SECRET` (`Apiary.KeyDerivation`): every machine
  pins this key, so it does not change when the encryption secret does, and the two are
  kept, lost and rotated apart. Losing it, or changing it, means every machine has to be
  pinned again.

  The seed is read from `config :apiary, Apiary.SigningKey, seed: <32 bytes>`, and the key
  is made from it on each call (`current/0`), which costs one Ed25519 key generation.

  **What is refused.** A seed that is not 32 bytes, and a seed the runner contract
  publishes, names or has published: in `fixtures/known-answers/keys.json`, the bytes 1
  to 32, 65 to 96 and 161 to 192; in its README, the second fixture access key's, 193 to
  224, whose secret is published elsewhere; and 33 to 64, the ephemeral key of a sealed
  fixture that earlier commits of the contract published. Apiary refuses each of them
  because it is published. The contract's sides refuse the keys of four of them, 1 to 32,
  65 to 96, 161 to 192 and 193 to 224; it names no refusal of the ephemeral key's, 33 to
  64, which Apiary alone refuses. `boot!/0` checks the seed when
  the application starts, and checks the public key it makes against the contract's key
  checks too (`Apiary.Contract.Ed25519.check_public_key/1`), so the instance does not
  start with a key a machine would refuse. Every refusal names the variable, never its
  value. Seeds are compared in constant time. In production, `config/runtime.exs` also
  refuses, before this module runs, a seed equal to `APIARY_ENCRYPTION_SECRET` and the
  development and test seeds that `config/dev.exs` and `config/test.exs` publish.

  **What it gives.**

    * `sign/1`, the Ed25519 signature of a message under the key, 64 raw bytes;
    * `public_key/0` and `fingerprint/0`, the raw public key and its fingerprint,
      `base64url(SHA-256(public key)[:16])`, 22 characters, which an enrolment code
      carries;
    * `apiary_public_key/0`, the list a discovery document and an enrolment answer give,
      `[%{"alg" => "ed25519", "public_key" => <base64url>}]`: the current key alone, as
      long as the key does not rotate. `apiary_public_key/1` gives the list of any keys,
      in order, which is how a rotation lists the current key, then the next.

  Building the answer string a signature covers is the caller's.

  **Holding it.** A key is a `t:t/0`, whose `inspect` shows the fingerprint and never the
  seed. Nothing here logs, and no error message carries the seed in any form.
  """

  alias Apiary.Contract.Ed25519

  @enforce_keys [:seed, :public_key]
  defstruct [:seed, :public_key]

  @typedoc """
  A signing key: its 32-byte seed and the raw public key made from it. `inspect` shows
  the fingerprint alone.
  """
  @opaque t :: %__MODULE__{seed: <<_::256>>, public_key: <<_::256>>}

  @typedoc "Why a seed is refused as the instance's key."
  @type refusal :: :length | :fixture | :key

  @variable "APIARY_SIGNING_SECRET"

  # The 32-byte values the runner contract publishes, or has published, in its fixtures,
  # each refused as a seed: the fixture access key's (bytes 1 to 32), the ephemeral key of
  # the sealed fixture of earlier commits (33 to 64), the fixture signing keys', current
  # and next (65 to 96, 161 to 192), and the second fixture access key the contract
  # published (193 to 224).
  @fixture_seeds Enum.map(
                   [1..32, 33..64, 65..96, 161..192, 193..224],
                   &:binary.list_to_bin(Enum.to_list(&1))
                 )

  @doc """
  new/1 is the key of a 32-byte `seed`, made without any check: Ed25519 (RFC 8032), the
  seed being the private key. The instance's own key is `current/0`, which checks its
  seed; this is for a key given explicitly, such as the contract's fixture signing key in
  a test of its known answers.
  """
  @spec new(<<_::256>>) :: t
  def new(<<_::binary-size(32)>> = seed) do
    {public_key, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    %__MODULE__{seed: seed, public_key: public_key}
  end

  # A clause of its own, so a wrong seed is never shown among the arguments of a
  # FunctionClauseError.
  def new(_seed), do: raise(ArgumentError, message(:length))

  @doc """
  current/0 is the instance's key, from the configured seed: see the module's
  documentation. Raises, naming #{@variable}, when the seed is not configured, is not 32
  bytes, or is a fixture seed.
  """
  @spec current() :: t
  def current do
    seed = configured_seed()

    case check_seed(seed) do
      :ok -> new(seed)
      {:error, refusal} -> raise ArgumentError, message(refusal)
    end
  end

  @doc """
  check_seed/1 says whether `seed` may be the instance's key: `:ok`, or
  `{:error, :length}` when it is not 32 bytes, or `{:error, :fixture}` when it is one of
  the runner contract's published fixture values. The comparison is in constant time.
  """
  @spec check_seed(term) :: :ok | {:error, :length | :fixture}
  def check_seed(<<_::binary-size(32)>> = seed) do
    # Every comparison runs, so the time taken says nothing about which seed matched.
    fixture? =
      Enum.reduce(@fixture_seeds, false, fn fixture, matched ->
        :crypto.hash_equals(seed, fixture) or matched
      end)

    if fixture?, do: {:error, :fixture}, else: :ok
  end

  def check_seed(_seed), do: {:error, :length}

  @doc """
  boot!/0 checks the configured seed and the public key it makes: the seed as
  `check_seed/1` does, and the public key against the contract's key checks
  (`Apiary.Contract.Ed25519.check_public_key/1`), which every machine runs on its pin.
  Called at boot; raises with a message that names #{@variable}, and never its value, so
  the instance does not start.
  """
  @spec boot!() :: :ok
  def boot! do
    key = current()

    case Ed25519.check_public_key(key.public_key) do
      :ok -> :ok
      {:error, :fixture} -> raise ArgumentError, message(:fixture)
      {:error, _other} -> raise ArgumentError, message(:key)
    end
  end

  @doc """
  sign/1 is the Ed25519 signature of `message` under the instance's key (`current/0`),
  64 raw bytes. sign/2 signs under the key given.
  """
  @spec sign(binary) :: <<_::512>>
  def sign(message) when is_binary(message), do: sign(current(), message)

  @spec sign(t, binary) :: <<_::512>>
  def sign(%__MODULE__{seed: seed}, message) when is_binary(message),
    do: :crypto.sign(:eddsa, :none, message, [seed, :ed25519])

  @doc "public_key/0 is the raw public key of the instance's key, 32 bytes; public_key/1 of the key given."
  @spec public_key() :: <<_::256>>
  def public_key, do: public_key(current())

  @spec public_key(t) :: <<_::256>>
  def public_key(%__MODULE__{public_key: public_key}), do: public_key

  @doc """
  fingerprint/0 is the fingerprint of the instance's key,
  `base64url(SHA-256(public key)[:16])`, 22 characters; fingerprint/1 of the key given.
  """
  @spec fingerprint() :: String.t()
  def fingerprint, do: fingerprint(current())

  @spec fingerprint(t) :: String.t()
  def fingerprint(%__MODULE__{public_key: public_key}), do: Ed25519.fingerprint(public_key)

  @doc """
  apiary_public_key/0 is the instance's `apiary_public_key` list: its current key alone,
  `[%{"alg" => "ed25519", "public_key" => <base64url>}]`. apiary_public_key/1 lists the
  keys given, in their order: the current key, then, during a rotation, the next.
  """
  @spec apiary_public_key() :: [%{required(String.t()) => String.t()}, ...]
  def apiary_public_key, do: apiary_public_key([current()])

  @spec apiary_public_key([t, ...]) :: [%{required(String.t()) => String.t()}, ...]
  def apiary_public_key([_ | _] = keys) do
    Enum.map(keys, fn %__MODULE__{public_key: public_key} ->
      %{"alg" => "ed25519", "public_key" => Ed25519.encode(public_key)}
    end)
  end

  defp configured_seed do
    Keyword.get(Application.get_env(:apiary, __MODULE__, []), :seed)
  end

  # Each message names the variable and says how to make a good one; none carries the
  # value, in any form.
  defp message(:length) do
    "#{@variable} is missing, or not 32 bytes (config :apiary, Apiary.SigningKey, seed:). " <>
      "It is 32 random bytes in base64. Generate one with: openssl rand -base64 32"
  end

  defp message(:fixture) do
    "#{@variable} is a value the runner contract publishes in its fixtures, so anyone " <>
      "could sign as this instance. Generate one with: openssl rand -base64 32"
  end

  defp message(:key) do
    "#{@variable} makes a public key the runner contract's key checks refuse. " <>
      "Generate one with: openssl rand -base64 32"
  end

  defimpl Inspect do
    # Shows the fingerprint, and nothing at all of a key that is not whole, so that no
    # failure here falls back to showing the fields.
    def inspect(%{public_key: <<_::binary-size(32)>>} = key, _opts) do
      "#Apiary.SigningKey<fingerprint: #{Kernel.inspect(Apiary.SigningKey.fingerprint(key))}>"
    end

    def inspect(_key, _opts), do: "#Apiary.SigningKey<>"
  end
end
