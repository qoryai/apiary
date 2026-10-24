defmodule Apiary.Registry.Credential do
  @moduledoc false

  # A run's registry credential, with the `registry` feature, which the documentation
  # leaves out: the `basic` credential the run's gateway sets on its requests to the
  # token route (`ApiaryWeb.RegistryTokenController`). Its user name is the run's public
  # id; its secret is 32 random bytes in unpadded base64url, made when the secrets request
  # seals it for the run's gateway (`Apiary.Runs.SecretsRequest`). The run's row keeps the
  # secret's SHA-256 alone (`runs.registry_credential_sha256`), stored once the seal
  # succeeded, and a second seal for the run replaces it, so only the secret sealed last
  # matches.
  #
  # `verify/2` compares the SHA-256 of the secret given with the stored one in constant
  # time, and compares it with a fixed value of the same length where the run is unknown
  # or has no credential, so the time taken does not say which. The credential works
  # while the run is live: pending or running, with its sending not ended
  # (`live?/1`); a token request of a run that ended fails, whatever the secret.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Repo
  alias Apiary.Runs.{Run, Sender}

  @name "registry"
  @absent :binary.copy(<<0>>, 32)

  @doc false
  # name/0 is the credential's name in the run configuration's `credentials`.
  @spec name() :: String.t()
  def name, do: @name

  @doc false
  # new_secret/0 is a fresh secret, stored nowhere until `store/2`.
  @spec new_secret() :: String.t()
  def new_secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc false
  # store/2 stores the SHA-256 of `secret` on `run`'s row, in place of any before it.
  # Raises where the row cannot be written.
  @spec store(Run.t(), String.t()) :: :ok
  def store(%Run{id: id}, secret) when is_binary(secret) do
    {1, _} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [registry_credential_sha256: :crypto.hash(:sha256, secret)]
      )

    :ok
  end

  @doc false
  # verify/2 is the run whose public id is `username` and whose credential is `secret`:
  # `{:ok, run}`, or `:error`.
  @spec verify(String.t(), String.t()) :: {:ok, Run.t()} | :error
  def verify(username, secret) when is_binary(username) and is_binary(secret) do
    run =
      if byte_size(username) <= 64,
        do: Repo.one(from r in Run, where: r.public_id == ^username)

    stored =
      case run do
        %Run{registry_credential_sha256: <<_::256>> = hash} -> hash
        _none -> @absent
      end

    matched = :crypto.hash_equals(stored, :crypto.hash(:sha256, secret))
    if matched and stored != @absent, do: {:ok, run}, else: :error
  end

  @doc false
  # live?/1 is whether `run`'s credential works: the run is pending or running, and its
  # sending has not ended.
  @spec live?(Run.t()) :: boolean
  def live?(%Run{} = run),
    do: run.state in Run.alive_states() and not Sender.sending_ended?(run)
end
