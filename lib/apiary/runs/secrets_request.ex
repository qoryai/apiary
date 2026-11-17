defmodule Apiary.Runs.SecretsRequest do
  @moduledoc false

  # With the `factory` and `secrets` features, or the `registry` feature (which the
  # documentation leaves out): the secrets request of the Forager contract
  # (`secrets-request.schema.json`), a gateway's signed POST for the values of credentials
  # of a run's run configuration, and its answer, the values sealed to the gateway's access
  # key (`Apiary.Secrets.Sealing`). The gateway names every credential when the run starts,
  # and at a renewal only the ones whose values expire. The credentials Qory writes are a
  # run's model keys (`Apiary.Runs.ProviderCredential`), with the `registry` feature, its
  # registry credential (`Apiary.Registry.Credential`), and the work entry and the push
  # entry its claim recorded (`Apiary.Runs.RunCredentials`, `work-1` and `push-1`), whose
  # value the entry's adapter issues anew for each request that names it
  # (`Apiary.Runs.WorkCredential`). A request may ask for either or both, as a renewal asks
  # for the entries whose values expire; each entry is a separate call to the adapter, with
  # the access of that entry. A request reveals a
  # model key only when it names it, and only a key the run's claim stored for the run
  # (`runs.model_keys`), by its row id, under the value id the key has at the request: a
  # key renamed since the claim is revealed, one removed since is refused at step 8. It
  # makes a registry secret only when it names `registry`, and the run's row keeps the
  # SHA-256 of the one sealed last.
  # `ApiaryWeb.Contract.SecretsController` verifies the request and answers it.
  #
  # The refusals, in order, after the request verified under the access key:
  #
  #  1. `{:error, :invalid_request}`, a body that fails the schema: not JSON, a member the
  #     schema does not define, a member twice, a member of the wrong form;
  #  2. `{:error, :unauthorized}`, a `timestamp` more than 300 seconds from the server's
  #     clock, either way;
  #  3. `{:error, :secrets_not_allowed}`, a key not allowed stored secrets, here where
  #     the `registry` feature is off for the run (the features it kept when it was
  #     claimed, `Apiary.Features.on?/2`), else at step 7, for a request that names the
  #     run's model key;
  #  4. as a reload of the run is refused (`Apiary.Runs.Registration.fetch/3`):
  #     `{:error, :not_found}` for a run that does not go through a gateway, since only a
  #     gateway seals, for a run whose run key does not list the access key among the
  #     gateway's keys (`Apiary.Runs.RunKey.lists_key?/2`), and for a run the key may not
  #     reload; then `{:error, :workspace_not_served}`; then `{:error, :gone}` for a run
  #     that is not live on the server's clock at the request
  #     (`Apiary.Runs.Sender.live?/2`): not pending or running, unless it is lost after
  #     its attach and not lost for good, or with its exit or its events pruned;
  #  5. `{:error, :run_configuration_superseded}`, a digest other than the one a reload
  #     of the run returns now: the gateway reads the run configuration and its digest
  #     from a reload;
  #  6. `{:error, :credential_unavailable}`, a run with no model provider, no registry
  #     credential and no work entry (a push entry comes with a work entry), or whose
  #     provider cannot be read: the run configuration has no credential, or none can be composed. The provider's columns
  #     of a run are NULL when its claim set no provider, or when the provider was
  #     deleted; a provider's deletion is refused while a live run uses it, as step 4
  #     reads it, so only a run that ended, refused at step 4, has them NULL after a
  #     deletion;
  #  7. `{:error, :credentials_differ}`, a `credentials` list that is not a subset of the
  #     credential names of that run configuration, in its order (the schema already
  #     refuses an empty list or a name twice); then `:secrets_not_allowed` for a key not
  #     allowed stored secrets, of a request that names the run's model key or its work
  #     entry; then `{:error, :not_found}` where `Apiary.Access` refuses the key
  #     `secret.seal` on the run, for a request that names the model key: a gateway that
  #     may no longer serve the run's workspace;
  #  8. `{:error, :credential_unavailable}`, a key Qory may not seal for the gateway (the
  #     checks of the provider apply to a request that names the model key): the
  #     provider's row, its secret or a named key fails its integrity check or is gone, or
  #     the key is no longer a value of the provider's secret; the provider's secret or
  #     chain differs from the run's; the provider's keys are a
  #     workspace's secret (`Apiary.Secrets.provider_keys_workspace/1`) and the run is of
  #     another workspace; the provider of the organisation's chain is of another
  #     organisation than the run's (`provider_organisation/2`); the gateway may not
  #     receive the key (`Apiary.Runs.ProviderCredential.sealable_to?/3`): any gateway
  #     for a provider of any other chain; the instance's gateway may receive a key of
  #     the organisation's chain; for a request for the work entry or the push entry, a
  #     gateway that may not receive its credential (`Apiary.Runs.WorkCredential.sealable_to?/2`);
  #     both checks are also false for a gateway of another organisation or of another
  #     workspace, whose request step 4 ends first; the access key's public key fails a
  #     key check (`Apiary.Contract.Ed25519.check_public_key/1`);
  #  9. for a request for the work entry or the push entry, after every check above and the
  #     model key's read, the credential of an entry is not issued
  #     (`Apiary.Runs.WorkCredential.issue/4`), the work entry's first, then the push
  #     entry's; the first that fails refuses the request, and no value is sealed:
  #     `{:error, :not_found}` where `Apiary.Access` refuses the key `run_credential.issue`
  #     on the run, the `factory` feature off among the causes, with no call and no
  #     Activity entry; `{:error, :unavailable}` for a call to the adapter that timed out
  #     or reached no one, `{:error, :gone}` for a run that is no longer live after the
  #     call, `{:error, :credential_unavailable}` for every other cause. No database
  #     transaction is open during the call;
  # 10. `{:error, :credential_unavailable}`, a value that does not fit the plaintext's
  #     schema;
  # 11. for a request for the work entry or the push entry, an entry's apply items
  #     differ from those of that entry's first credential
  #     (`Apiary.Runs.WorkCredential.keep/1`): `{:error, :credential_unavailable}`.
  #
  # Each attempt at an entry's credential that `Apiary.Access` lets, from step 9 on,
  # writes one `run_credential.issue` Activity entry per entry: its refusal, or, last
  # before the answer and in one transaction with its apply items and the seal's audit
  # entry, `issued`. A request for both entries fails whole: the entry that failed has its
  # cause, and an entry whose credential was issued before has `not_recorded`.
  #
  # `{:error, :unavailable}` when the run configuration cannot be read, or the seal or its
  # audit entry fails. A seal of model keys is recorded as `secret.seal`, by the access
  # key, with the provider's public id, the first named key's credential name
  # (`credential`) and every named key's (`credentials`), in the run's organisation's
  # trail, about the run. In one transaction with that entry, before it, a row per named
  # key keeps when the sealed value was set (`Apiary.ModelKeys.keep_copies/2`). A seal
  # without a model key is not recorded.
  #
  # The value goes into the seal and nowhere else: no log line, error, exception message
  # or audit entry has it, nor the plaintext, the sealed bytes or a key. A log line has
  # the run's id, the provider's, connection's and adapter's public ids and a refusal's
  # atom at most.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Access, Audit, Features, ModelKeys, Repo, Secrets}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Contract.Ed25519
  alias Apiary.Organisations.Organisation
  alias Apiary.Registry.{Credential, RunAccess}

  alias Apiary.Runs.{
    ProviderCredential,
    Registration,
    Run,
    RunCredentials,
    RunKey,
    Sender,
    WorkCredential
  }

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
    access_key = Repo.preload(access_key, [:workspace, :node])

    with {:ok, request} <- parse(raw_body),
         :ok <- fresh(request, now),
         :ok <- allowed(access_key, request) do
      for_run(access_key, request, instance_id, now)
    end
  end

  # The credentials are read before the reload, which cannot compose a run configuration
  # without them, and their refusal follows the digest's.
  defp for_run(access_key, request, instance_id, now) do
    with {:ok, run} <- run(access_key, request.run_id, instance_id, now),
         credentials = credentials(run),
         {:ok, digest} <- in_force(access_key, run, instance_id, credentials),
         :ok <- same_digest(request, digest),
         {:ok, credentials} <- credentials,
         {:ok, %{model: model, works: works} = credentials} <- named(request, credentials),
         :ok <- stored_allowed(model, works, access_key),
         :ok <- may_seal(run, model, access_key),
         :ok <- sealable(run, model, access_key),
         :ok <- work_sealable(run, works, access_key),
         {:ok, public_key} <- recipient_key(run, access_key),
         {:ok, values, secret, copies} <- values(run, credentials),
         {:ok, issued} <- issued(run, works, access_key, now),
         {:ok, body} <-
           sealed(run, credentials, values, issued, access_key, public_key, digest, now),
         :ok <- recorded(access_key, run, {model, copies}, issued) do
      # The registry credential's secret counts from here: the seal and its size check
      # succeeded, and so did the seal's audit entry, which only a request that names the
      # model key has, and the work credential's writes. The answer goes out with the
      # secret.
      if secret, do: :ok = Credential.store(run, secret)
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
    length(names) <= 16 and Enum.uniq(names) == names and
      Enum.all?(names, &(is_binary(&1) and &1 =~ @credential))
  end

  defp valid?("credentials", _value), do: false

  defp valid?("timestamp", value),
    do: is_integer(value) and value >= 0 and value <= @max_timestamp

  defp fresh(%{timestamp: timestamp}, now) do
    if abs(timestamp - now) <= @window_seconds, do: :ok, else: {:error, :unauthorized}
  end

  # A key not allowed stored secrets is refused here, unless the `registry` feature is on
  # among the features the request's run kept when it was claimed, or the instance's for a
  # run that kept none, that has ended, or that the key does not find
  # (`Apiary.Runs.Sender.recorded/2`, `Apiary.Features.on?/2`): then it
  # may receive a run's registry credential, and is refused only where the request names
  # the run's model key or its work entry (`stored_allowed/2`).
  defp allowed(%AccessKey{allow_secrets: true}, _request), do: :ok

  defp allowed(%AccessKey{} = access_key, %{run_id: run_id}) do
    if Features.on?(:registry, Sender.recorded(access_key, run_id)),
      do: :ok,
      else: {:error, :secrets_not_allowed}
  end

  defp stored_allowed(nil, [], _access_key), do: :ok
  defp stored_allowed(_model, _works, %AccessKey{allow_secrets: true}), do: :ok
  defp stored_allowed(_model, _works, %AccessKey{}), do: {:error, :secrets_not_allowed}

  # Only a request that names the run's model key seals it: one for `registry` alone asks
  # nothing here, as the `factory` feature of `secret.seal` may be off under `registry`.
  # The model key is nil without that feature (`Apiary.Runs.ProviderCredential.applies?/0`).
  defp may_seal(_run, nil, _access_key), do: :ok

  defp may_seal(%Run{} = run, %{}, access_key) do
    case Access.check(Scope.for_access_key(access_key), :"secret.seal", run) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  ## The run, as a reload reads it

  defp run(access_key, run_id, instance_id, now) do
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

          not Sender.live?(run, DateTime.from_unix!(now)) ->
            {:error, :gone}

          true ->
            {:ok, run}
        end

      nil ->
        {:error, :not_found}
    end
  end

  # The run's credentials, as its run configuration contains them: `{:ok, %{model:,
  # registry:, works:, names:}}`, the model key (nil for none), whether the run has a
  # registry credential (`Apiary.Registry.RunAccess`), its work entry and its push entry
  # (`Apiary.Runs.RunCredentials.work/1` and `push/1`; `[]` for none, the work entry
  # first), and their names in the document's order. `:credential_unavailable` for a run
  # with none, and for a run whose model provider cannot be read.
  defp credentials(%Run{} = run) do
    with {:ok, model} <- model(run) do
      registry = RunAccess.applies?(run)
      works = Enum.reject([RunCredentials.work(run), RunCredentials.push(run)], &is_nil/1)

      names =
        if(model, do: Enum.map(model.keys, & &1.name), else: []) ++
          if(registry, do: [Credential.name()], else: []) ++
          Enum.map(works, & &1.name)

      if names == [],
        do: {:error, :credential_unavailable},
        else: {:ok, %{model: model, registry: registry, works: works, names: names}}
    end
  end

  defp model(%Run{provider_api: %{}, model_keys: [_ | _]} = run)
       when is_binary(run.provider_connection_id) and is_binary(run.provider_secret_id) do
    case ProviderCredential.for_run(run) do
      {:ok, %{} = credential} -> {:ok, credential}
      {:ok, nil} -> {:ok, nil}
      {:error, :unavailable} -> {:error, :credential_unavailable}
    end
  end

  defp model(%Run{}), do: {:ok, nil}

  # The digest a reload of the run returns now, with the reload's refusals. A reload that
  # fails while the credentials cannot be read is the credentials' refusal.
  defp in_force(access_key, run, instance_id, credentials) do
    case Registration.fetch(access_key, run.node_run_id, instance_id) do
      {:ok, %{digest: digest}} -> {:ok, digest}
      {:error, :not_found} -> {:error, :run_configuration_superseded}
      {:error, :workspace_not_served} -> {:error, :workspace_not_served}
      {:error, _reason} -> with {:ok, _credentials} <- credentials, do: {:error, :unavailable}
    end
  end

  defp same_digest(%{run_configuration: digest}, digest), do: :ok
  defp same_digest(_request, _digest), do: {:error, :run_configuration_superseded}

  # The credentials the request names: a subset of the run's, in the run configuration's
  # order. The model keys are those of the run's keys that the request names, nil for
  # none; the work entries are the run's entries the request names, `[]` for none, and the
  # registry credential is false, where the request does not name it.
  defp named(%{credentials: requested}, %{model: model, registry: registry} = credentials) do
    if Enum.filter(credentials.names, &(&1 in requested)) == requested do
      {:ok,
       %{
         model: model_named(model, requested),
         registry: registry and Credential.name() in requested,
         works: Enum.filter(credentials.works, &(&1.name in requested)),
         names: requested
       }}
    else
      {:error, :credentials_differ}
    end
  end

  defp model_named(nil, _requested), do: nil

  defp model_named(model, requested) do
    case Enum.filter(model.keys, &(&1.name in requested)) do
      [] -> nil
      keys -> %{model | keys: keys}
    end
  end

  ## What may be sealed for the gateway

  defp sealable(_run, nil, _access_key), do: :ok

  defp sealable(%Run{} = run, %{provider: provider}, access_key),
    do: sealable_provider(run, provider, access_key)

  defp sealable_provider(%Run{} = run, provider, %AccessKey{node: node}) do
    cond do
      provider.secret_id != run.provider_secret_id ->
        refused(run, provider, :secret)

      provider.chain != run.provider_chain ->
        refused(run, provider, :chain)

      not keys_of_run_workspace?(provider, run) ->
        refused(run, provider, :workspace)

      provider.organisation_id != provider_organisation(provider, run) ->
        refused(run, provider, :organisation)

      not ProviderCredential.sealable_to?(provider.chain, node, run) ->
        refused(run, provider, :gateway)

      true ->
        :ok
    end
  end

  # A provider's keys kept as the organisation's secret may be sealed for a run of any of
  # its workspaces the provider reaches; kept as a workspace's secret, only for a run of
  # that workspace.
  defp keys_of_run_workspace?(provider, %Run{workspace_id: workspace_id}) do
    case Secrets.provider_keys_workspace(provider) do
      {:ok, nil} -> true
      {:ok, ^workspace_id} -> true
      _other -> false
    end
  end

  # The organisation whose providers make up the chain of `provider` for the run: the run's
  # organisation for the organisation's chain. For a provider of any other chain, the
  # provider's organisation is taken, so that the gateway check refuses the key
  # (`Apiary.Runs.ProviderCredential.sealable_to?/3`).
  defp provider_organisation(%{chain: "organisation"}, %Run{organisation_id: id}), do: id
  defp provider_organisation(provider, _run), do: provider.organisation_id

  # The work entry's and the push entry's credentials may be sealed for a gateway of the
  # run's organisation, or the instance's gateway (`Apiary.Runs.WorkCredential.sealable_to?/2`).
  defp work_sealable(_run, [], _access_key), do: :ok

  defp work_sealable(%Run{} = run, [_ | _], %AccessKey{node: node}) do
    if WorkCredential.sealable_to?(node, run) do
      :ok
    else
      Logger.warning(
        "a secrets request for the run #{run.node_run_id} was refused: its work " <>
          "credential may not be sealed for its gateway"
      )

      {:error, :credential_unavailable}
    end
  end

  # The credentials of the entries the request names, from their adapter, one call each, in
  # the order of the run configuration (`Apiary.Runs.WorkCredential.issue/4`): `{:ok, []}`
  # where the request names no entry. The first refusal is the request's, and an
  # entry issued before it is refused, never sent (`not_recorded`). Every step before it
  # needs no token.
  defp issued(run, works, access_key, now) do
    Enum.reduce_while(works, {:ok, []}, fn %{row: row}, {:ok, issued} ->
      case WorkCredential.issue(run, row, access_key, now) do
        {:ok, credential} ->
          {:cont, {:ok, issued ++ [credential]}}

        {:error, _refusal} = error ->
          Enum.each(issued, &WorkCredential.refused(access_key, run, &1, :not_recorded))
          {:halt, error}
      end
    end)
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

  # The seal of `values` and the credentials `issued` of the work and push entries, in
  # memory. A seal that fails after a credential was issued is its refusal too
  # (`Apiary.Runs.WorkCredential.refused/4`).
  defp sealed(run, credentials, values, issued, access_key, public_key, digest, now) do
    work_values = Enum.map(issued, &WorkCredential.value(&1.row.name, &1.issued))
    values = Enum.sort_by(values ++ work_values, & &1["credential"])

    plaintext = %{
      "version" => 1,
      "run_configuration" => digest,
      "credentials" => Enum.sort(credentials.names),
      "values" => values
    }

    recipient = %{
      access_key_id: access_key.key_id,
      public_key: public_key,
      run_id: run.node_run_id,
      run_configuration: digest,
      exp: Sealing.expiry(DateTime.from_unix!(now))
    }

    case seal(run, credentials.model, plaintext, recipient) do
      {:ok, body} ->
        {:ok, body}

      {:error, _code} = error ->
        Enum.each(issued, &WorkCredential.refused(access_key, run, &1, :seal_failed))
        error
    end
  end

  # The writes after the seal. Without a work or push credential, the seal's records alone
  # (`record/3`). With them, in one transaction: the seal's records, whose copies of the
  # model keys take the run's row `FOR KEY SHARE` first; then each entry's apply items
  # kept or compared on its `run_credentials` row (`Apiary.Runs.WorkCredential.keep/1`);
  # then each credential's Activity entry, last. A run's deletion locks the run's row
  # and then its `run_credentials` rows, so both take the run first and cannot deadlock;
  # a request for one entry and no model key has no copies and takes no lock on the run;
  # a request for both entries takes the run's row `FOR KEY SHARE` before the first
  # update (`lock_run/1`), since a deletion removes the two rows in no fixed order. A step
  # that fails rolls them all back, and the credential it failed on is refused for its
  # cause, the others as `not_recorded` (`Apiary.Runs.WorkCredential.refused/4`).
  defp recorded(access_key, run, seal, []), do: record(access_key, run, seal)

  defp recorded(access_key, run, seal, issued) do
    written =
      try do
        Repo.transact(fn ->
          with :ok <- not_recorded(record(access_key, run, seal)),
               :ok <- not_recorded(lock_run(run, issued)),
               :ok <- each_issued(issued, &WorkCredential.keep/1),
               :ok <- each_issued(issued, &WorkCredential.record_issued(access_key, run, &1)),
               do: {:ok, :written}
        end)
      rescue
        _exception -> {:error, :not_recorded}
      end

    case written do
      {:ok, :written} -> :ok
      {:error, failure} -> refused_all(access_key, run, issued, failure)
    end
  end

  defp not_recorded(:ok), do: :ok
  defp not_recorded({:error, _reason}), do: {:error, :not_recorded}

  # The run's row `FOR KEY SHARE`, which the run's deletion waits for, so that two updates
  # of the run's `run_credentials` rows and the deletion's removal of them cannot wait for
  # each other. One update needs none. `{:error, :gone}` for a run that was deleted.
  defp lock_run(%Run{id: id}, [_, _ | _]) do
    case Repo.one(from r in Run, where: r.id == ^id, select: r.id, lock: "FOR KEY SHARE") do
      ^id -> :ok
      nil -> {:error, :gone}
    end
  end

  defp lock_run(_run, _issued), do: :ok

  # `:ok` when `step` returns `:ok` for each credential in `issued`, else the first
  # refusal, with the credential it was for.
  defp each_issued(issued, step) do
    Enum.find_value(issued, :ok, fn credential ->
      case step.(credential) do
        :ok -> nil
        {:error, cause} -> {:error, {cause, credential}}
      end
    end)
  end

  # Every credential in `issued` is refused: the one a step failed on for `cause`, the
  # others, and all where no step is to blame, as `not_recorded`. The refusal of the one
  # that failed, else the first, is the request's.
  defp refused_all(access_key, run, issued, failure) do
    {cause, failed} =
      case failure do
        {cause, credential} -> {cause, credential}
        cause -> {cause, nil}
      end

    results =
      Enum.map(issued, fn credential ->
        reason = if is_nil(failed) or credential == failed, do: cause, else: :not_recorded
        {credential, WorkCredential.refused(access_key, run, credential, reason)}
      end)

    {_credential, refusal} = Enum.find(results, hd(results), &(elem(&1, 0) == failed))
    refusal
  end

  # The value of each credential but the work entry's, the registry credential's secret,
  # nil for none, and the copies of the model keys (`model_value/2`): the model keys',
  # read for sealing before the work entry's credential is requested, and the registry
  # credential's, made now (`Apiary.Registry.Credential.new_secret/0`) and stored only
  # once the seal succeeded.
  defp values(run, %{model: model, registry: registry}) do
    with {:ok, model_values, copies} <- model_value(run, model) do
      secret = if registry, do: Credential.new_secret()

      registry_values =
        if secret, do: [%{"credential" => Credential.name(), "value" => secret}], else: []

      {:ok, model_values ++ registry_values, secret, copies}
    end
  end

  defp model_value(_run, nil), do: {:ok, [], []}

  # Each named key of the run, revealed by its row id, under the value id it has now
  # (`Apiary.Secrets.reveal_key_and_set_at/2`): a key renamed since the claim is
  # revealed, and for one removed since, or no longer a value of the provider's secret,
  # this returns a refusal, `{:error, :credential_unavailable}`. With the copies,
  # `[{secret_value_id, value_set_at}]`, when each revealed value was set, read with it
  # (`Apiary.ModelKeys.keep_copies/2`).
  defp model_value(run, credential) do
    Enum.reduce_while(credential.keys, {:ok, [], []}, fn key, {:ok, values, copies} ->
      case Secrets.reveal_key_and_set_at(credential.provider, key.secret_value_id) do
        {:ok, value, value_set_at} ->
          {:cont,
           {:ok, values ++ [%{"credential" => key.name, "value" => value}],
            [{key.secret_value_id, value_set_at} | copies]}}

        {:error, reason} ->
          Logger.error(
            "a secrets request for the run #{run.node_run_id} was refused: the key " <>
              "#{key.name} of the model provider #{credential.provider.public_id} cannot " <>
              "be read (#{reason})"
          )

          {:halt, {:error, :credential_unavailable}}
      end
    end)
  end

  defp seal(run, credential, plaintext, recipient) do
    case Sealing.seal(plaintext, recipient) do
      {:ok, body} when byte_size(body) <= @max_answer_bytes ->
        {:ok, body}

      {:ok, _body} ->
        {:error, :unavailable}

      {:error, refusal} ->
        if credential do
          Logger.error(
            "the key of the model provider #{credential.provider.public_id} for the run " <>
              "#{run.node_run_id} could not be sealed (#{refusal})"
          )
        else
          Logger.error(
            "the credentials for the run #{run.node_run_id} could not be sealed (#{refusal})"
          )
        end

        if refusal == :value, do: {:error, :credential_unavailable}, else: {:error, :unavailable}
    end
  end

  # The records of the seal, for a request that lists the run's model key, in one
  # transaction: the copies of its keys (`Apiary.ModelKeys.keep_copies/2`), then the
  # audit entry; the answer to such a request goes out only with both. A request that
  # does not list it, such as one for `registry` alone, gets neither. The entry goes in the
  # run's organisation's trail, about the run, and the access key acts in that
  # organisation (`Apiary.Accounts.Scope.key_in_organisation/2`).
  defp record(_access_key, _run, {nil, _copies}), do: :ok

  defp record(access_key, run, {credential, copies}) do
    details = %{
      "provider_id" => credential.provider.public_id,
      "credential" => hd(credential.keys).name,
      "credentials" => Enum.map(credential.keys, & &1.name)
    }

    Repo.transact(fn ->
      with %Organisation{} = organisation <- Repo.get(Organisation, run.organisation_id),
           :ok <- ModelKeys.keep_copies(run.id, copies),
           scope = Scope.key_in_organisation(Scope.for_access_key(access_key), organisation),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"secret.seal", run, %{details: details}) do
        {:ok, :recorded}
      else
        _failed -> {:error, :unavailable}
      end
    end)
    |> case do
      {:ok, :recorded} -> :ok
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end
end
