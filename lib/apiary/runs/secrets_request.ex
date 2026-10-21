defmodule Apiary.Runs.SecretsRequest do
  @moduledoc false

  # With the `factory` and `secrets` features, which the documentation leaves out: the
  # secrets request of the Forager contract (`secrets-request.schema.json`), a gateway's
  # signed POST for the value of each credential of a run's run configuration, and its
  # answer, the values sealed to the gateway's access key (`Apiary.Secrets.Sealing`). The
  # one credential Qory writes is a run's model key (`Apiary.Runs.ProviderCredential`).
  # `ApiaryWeb.Contract.SecretsController` verifies the request and answers it.
  #
  # The refusals, in order, after the request verified under the access key:
  #
  #  1. `{:error, :invalid_request}`, a body that fails the schema: not JSON, a member the
  #     schema does not define, a member twice, a member of the wrong form;
  #  2. `{:error, :unauthorized}`, a `timestamp` more than 300 seconds from the server's
  #     clock, either way;
  #  3. `{:error, :secrets_not_allowed}`, a key not allowed stored secrets;
  #  4. as a reload of the run is refused (`Apiary.Runs.Registration.fetch/3`):
  #     `{:error, :not_found}` for a run that does not go through a gateway, since only a
  #     gateway seals, for a run whose run key does not list the access key among the
  #     gateway's keys (`Apiary.Runs.RunKey.lists_key?/2`), and for a run the key may not
  #     reload; then `{:error, :workspace_not_served}`; then `{:error, :gone}` for a run
  #     that is not live: not pending or running, or its sending ended
  #     (`Apiary.Runs.Sender`);
  #  5. `{:error, :run_configuration_superseded}`, a digest other than the one a reload
  #     of the run returns now: the gateway reads the run configuration and its digest
  #     from a reload;
  #  6. `{:error, :credential_unavailable}`, a run with no model provider, or whose
  #     provider cannot be read: the run configuration has no credential, or none can be
  #     composed. The provider's columns of a run are NULL when the handover set no
  #     provider, or when the provider was deleted; a provider's deletion is refused while
  #     a pending or running run uses it, so only a run that ended, refused at step 4,
  #     has them NULL after a deletion;
  #  7. `{:error, :credentials_differ}`, a `credentials` list other than the credential
  #     names of that run configuration, in its order;
  #  8. `{:error, :credential_unavailable}`, a key Qory may not seal for the gateway: the
  #     provider's row, its secret or the value fails its integrity check or is gone; the
  #     provider's secret or chain differs from the run's; the provider's organisation is
  #     not the run's; the gateway's organisation may not receive the key
  #     (`Apiary.Runs.ProviderCredential.sealable_to?/3`): for a provider of the
  #     organisation's chain, a gateway of another organisation, and for a provider of an
  #     operator's chain, a gateway of the run's organisation, of an organisation whose
  #     gateways do not serve the run's, or any gateway once the edition returns another
  #     chain than "operator" for the run's organisation
  #     (`c:Apiary.Edition.model_choice_chain/1`); the access key's public key fails a key
  #     check (`Apiary.Contract.Ed25519.check_public_key/1`); the value does not fit the
  #     plaintext's schema.
  #
  # `{:error, :unavailable}` when the run configuration cannot be read, or the seal or its
  # audit entry fails. A seal is recorded in the audit trail of the gateway's
  # organisation, `secret.seal`, with the provider's public id and the credential's name,
  # about the run; for a run of another organisation, about the gateway, with the run's
  # id.
  #
  # The value goes into the seal and nowhere else: no log line, error, exception message
  # or audit entry has it, nor the plaintext, the sealed bytes or a key. A log line has
  # the run's id, the provider's public id and a refusal's atom at most.

  require Logger

  alias Apiary.{Audit, Repo, Secrets}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Contract.Ed25519
  alias Apiary.Runs.{ProviderCredential, Registration, Run, RunKey, Sender}
  alias Apiary.Secrets.Sealing

  @members ~w(version run_id run_configuration credentials timestamp)
  @run_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @digest ~r/\Asha256=[0-9a-f]{64}\z/
  @credential ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/
  @max_timestamp Integer.pow(2, 53) - 1
  @window_seconds 300
  # The contract's limit on the answer's body.
  @max_answer_bytes 5 * 1024 * 1024

  @type refusal ::
          :invalid_request
          | :unauthorized
          | :secrets_not_allowed
          | :not_found
          | :workspace_not_served
          | :gone
          | :credential_unavailable
          | :run_configuration_superseded
          | :credentials_differ
          | :unavailable

  @doc false
  # answer/4 is the body of the answer to `raw_body`, a secrets request verified under
  # `access_key` from the instance `instance_id`, at `now` (Unix seconds): `{:ok, bytes}`,
  # or `{:error, refusal}` in the order of the comment after the moduledoc.
  @spec answer(AccessKey.t(), binary, String.t() | nil, integer) ::
          {:ok, binary} | {:error, refusal}
  def answer(%AccessKey{} = access_key, raw_body, instance_id, now) when is_integer(now) do
    with {:ok, request} <- parse(raw_body),
         :ok <- fresh(request, now),
         :ok <- allowed(access_key) do
      access_key = Repo.preload(access_key, [:workspace, :node])
      for_run(access_key, request, instance_id, now)
    end
  end

  # The credential is read before the reload, which cannot compose a run configuration
  # without it, and its refusal follows the digest's.
  defp for_run(access_key, request, instance_id, now) do
    with {:ok, run} <- run(access_key, request.run_id, instance_id),
         credential = credential(run),
         {:ok, digest} <- in_force(access_key, run, instance_id, credential),
         :ok <- same_digest(request, digest),
         {:ok, credential} <- credential,
         :ok <- same_names(request, credential),
         :ok <- sealable(run, credential.provider, access_key),
         {:ok, public_key} <- recipient_key(run, access_key),
         {:ok, body} <- sealed(run, credential, access_key, public_key, digest, now),
         :ok <- record(access_key, run, credential) do
      {:ok, body}
    end
  end

  ## The request

  @doc false
  # parse/1 is the request in `raw_body`, `{:ok, %{run_id, run_configuration, credentials,
  # timestamp}}`, or `{:error, :invalid_request}`.
  @spec parse(term) :: {:ok, map} | {:error, :invalid_request}
  def parse(raw_body) when is_binary(raw_body) do
    with {:ok, %Jason.OrderedObject{values: values}} <-
           Jason.decode(raw_body, objects: :ordered_objects),
         names = Enum.map(values, &elem(&1, 0)),
         true <- Enum.sort(names) == Enum.sort(@members),
         fields = Map.new(values),
         true <- Enum.all?(@members, &valid?(&1, fields[&1])) do
      {:ok,
       %{
         run_id: fields["run_id"],
         run_configuration: fields["run_configuration"],
         credentials: fields["credentials"],
         timestamp: fields["timestamp"]
       }}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  def parse(_raw_body), do: {:error, :invalid_request}

  defp valid?("version", value), do: value === 1
  defp valid?("run_id", value), do: is_binary(value) and value =~ @run_id
  defp valid?("run_configuration", value), do: is_binary(value) and value =~ @digest

  defp valid?("credentials", [_ | _] = names) do
    length(names) <= 8 and Enum.uniq(names) == names and
      Enum.all?(names, &(is_binary(&1) and &1 =~ @credential))
  end

  defp valid?("credentials", _value), do: false

  defp valid?("timestamp", value),
    do: is_integer(value) and value >= 0 and value <= @max_timestamp

  defp fresh(%{timestamp: timestamp}, now) do
    if abs(timestamp - now) <= @window_seconds, do: :ok, else: {:error, :unauthorized}
  end

  defp allowed(%AccessKey{allow_secrets: true}), do: :ok
  defp allowed(%AccessKey{}), do: {:error, :secrets_not_allowed}

  ## The run, as a reload reads it

  defp run(access_key, run_id, instance_id) do
    case Repo.one(Sender.run_query(access_key, run_id)) do
      %Run{} = run ->
        cond do
          not Run.through_gateway?(run) ->
            {:error, :not_found}

          not RunKey.lists_key?(run.run_key_payload, access_key.public_key) ->
            {:error, :not_found}

          not Registration.reload_allowed?(access_key, run, instance_id) ->
            {:error, :not_found}

          not Sender.serves?(run, access_key) ->
            {:error, :workspace_not_served}

          not live?(run) ->
            {:error, :gone}

          true ->
            {:ok, run}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp live?(%Run{} = run),
    do: run.state in Run.alive_states() and not Sender.sending_ended?(run)

  # The run's model key, as its run configuration contains it; `:credential_unavailable`
  # for a run with none, or whose provider cannot be read.
  defp credential(%Run{provider_api: %{}, provider_value_id: value_id} = run)
       when is_binary(value_id) and is_binary(run.provider_connection_id) and
              is_binary(run.provider_secret_id) do
    case ProviderCredential.for_run(run) do
      {:ok, %{} = credential} -> {:ok, credential}
      {:ok, nil} -> {:error, :credential_unavailable}
      {:error, :unavailable} -> {:error, :credential_unavailable}
    end
  end

  defp credential(%Run{}), do: {:error, :credential_unavailable}

  # The digest a reload of the run returns now, with the reload's refusals. A reload that
  # fails while the credential cannot be read is the credential's refusal.
  defp in_force(access_key, run, instance_id, credential) do
    case Registration.fetch(access_key, run.node_run_id, instance_id) do
      {:ok, %{digest: digest}} -> {:ok, digest}
      {:error, :not_found} -> {:error, :run_configuration_superseded}
      {:error, :workspace_not_served} -> {:error, :workspace_not_served}
      {:error, _reason} -> with {:ok, _credential} <- credential, do: {:error, :unavailable}
    end
  end

  defp same_digest(%{run_configuration: digest}, digest), do: :ok
  defp same_digest(_request, _digest), do: {:error, :run_configuration_superseded}

  defp same_names(%{credentials: [name]}, %{name: name}), do: :ok
  defp same_names(_request, _credential), do: {:error, :credentials_differ}

  ## What may be sealed for the gateway

  defp sealable(%Run{} = run, provider, %AccessKey{node: node}) do
    cond do
      provider.secret_id != run.provider_secret_id ->
        refused(run, provider, :secret)

      provider.chain != run.provider_chain ->
        refused(run, provider, :chain)

      provider.organisation_id != run.organisation_id ->
        refused(run, provider, :organisation)

      not ProviderCredential.sealable_to?(
        provider.chain,
        node.organisation_id,
        run.organisation_id
      ) ->
        refused(run, provider, :gateway)

      true ->
        :ok
    end
  end

  defp recipient_key(run, %AccessKey{public_key: public_key}) do
    case Ed25519.check_public_key(public_key) do
      :ok ->
        {:ok, public_key}

      {:error, refusal} ->
        Logger.error(
          "a secrets request for the run #{run.node_run_id} was refused: the access key " <>
            "it verified under fails the key check #{refusal}"
        )

        {:error, :credential_unavailable}
    end
  end

  defp refused(run, provider, why) do
    Logger.warning(
      "a secrets request for the run #{run.node_run_id} was refused: the model provider " <>
        "#{provider.public_id} may not be sealed for its gateway (#{why})"
    )

    {:error, :credential_unavailable}
  end

  ## The seal

  defp sealed(run, credential, access_key, public_key, digest, now) do
    case Secrets.reveal_for_sealing(credential.provider, run.provider_value_id) do
      {:ok, value} ->
        plaintext = %{
          "version" => 1,
          "run_configuration" => digest,
          "credentials" => [credential.name],
          "values" => [%{"credential" => credential.name, "value" => value}]
        }

        recipient = %{
          access_key_id: access_key.key_id,
          public_key: public_key,
          run_id: run.node_run_id,
          run_configuration: digest,
          exp: Sealing.expiry(DateTime.from_unix!(now))
        }

        seal(run, credential, plaintext, recipient)

      {:error, reason} ->
        Logger.error(
          "a secrets request for the run #{run.node_run_id} was refused: the key of the " <>
            "model provider #{credential.provider.public_id} cannot be read (#{reason})"
        )

        {:error, :credential_unavailable}
    end
  end

  defp seal(run, credential, plaintext, recipient) do
    case Sealing.seal(plaintext, recipient) do
      {:ok, body} when byte_size(body) <= @max_answer_bytes ->
        {:ok, body}

      {:ok, _body} ->
        {:error, :unavailable}

      {:error, refusal} ->
        Logger.error(
          "the key of the model provider #{credential.provider.public_id} for the run " <>
            "#{run.node_run_id} could not be sealed (#{refusal})"
        )

        if refusal == :value, do: {:error, :credential_unavailable}, else: {:error, :unavailable}
    end
  end

  # The audit entry of the seal, in the gateway's organisation: no answer is sent
  # without it. Its subject is the run, or, for a run of another organisation, which an
  # operator's gateway serves, the gateway, with the run's id in its details: an entry's
  # subject is of the trail's organisation.
  defp record(access_key, run, credential) do
    details = %{
      "provider_id" => credential.provider.public_id,
      "credential" => credential.name
    }

    {subject, details} =
      if run.organisation_id == access_key.organisation_id,
        do: {run, details},
        else: {access_key.node, Map.put(details, "run_id", run.node_run_id)}

    case Audit.record(Repo, Scope.for_access_key(access_key), :"secret.seal", subject, %{
           details: details
         }) do
      {:ok, _entry} -> :ok
      {:error, _changeset} -> {:error, :unavailable}
    end
  end
end
