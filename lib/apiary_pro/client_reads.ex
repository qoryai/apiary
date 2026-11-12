defmodule ApiaryPro.ClientReads do
  # What a person of an operated client reads of its runs, narrowed
  # (`c:Apiary.Edition.client_reads/4`): the model provider of the operator's chain is not
  # shown, neither its credential, nor its connections, nor its events. Not in the
  # published documentation: the narrowing applies only while a flag is on, and what a flag
  # hides is not named there.
  #
  # The narrowing applies when all of these hold: the scope's organisation is a client of an
  # operator, the scope's person does not reach it through the operator
  # (`ApiaryPro.Reach`: the operator's people read everything), the flag
  # `operator_infrastructure` is on (`ApiaryPro.Flags.operator_infrastructure?/0`), and the
  # run's `provider_chain` is "operator". Anything else is returned as it is.
  #
  # The provider's entries. A run's `policy.applied` events list its credentials, each
  # with a `name` and the `hosts` it was used for, as recorded when the run was claimed. The
  # provider's entries are those named like one of the run's model keys (`runs.model_keys`:
  # `<public id>-1` to `<public id>-6`, or the provider row's public id on a run claimed
  # when a run kept one key), with the provider's row there or gone, and, while that row is
  # there, those named like the row, the connection `provider_connection_id` links to
  # (`Apiary.Runs.ProviderCredential`). The hosts come from the recorded entries, never
  # from the row as it is now, which an edit of its address changes. A run with no key
  # names and no row (a run claimed before model keys, whose provider row was deleted
  # before its keys were recorded: its `model_keys` list is empty) is read by the host of
  # its recorded `provider_api` endpoint: the entries are those whose hosts include that
  # host; when no entry has it, every entry could be the provider's and every one is taken,
  # so the person also loses the other credentials of that run (a registry credential, for
  # one) and their hosts.
  #
  # What is removed. The entries, from every `policy.applied` map read
  # (`:run_policy` narrows the map it is given, from that map's credentials); the provider's
  # hosts from that map's `allow`, `allow_first` and `terminated` lists, with their counts
  # lowered by the hosts taken out; the provider's hosts from the `hosts` of each of that
  # map's `tools`, where the tools and `tools_count` stay; the events and connections whose
  # credential is one of the entries; and the connections and egress events to one of its
  # hosts or to the host of the run's recorded endpoint, whatever their credential. The
  # endpoint host is hidden even where the row is gone and the events are pruned, which
  # leave the connections (`Apiary.Retention`). Each query is narrowed in the database, so
  # no rows are read to be dropped.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Connections.Connection
  alias Apiary.Repo
  alias Apiary.Runs.Run
  alias ApiaryPro.{Flags, Tenants}

  @policy_applied "dev.qory.run.policy_applied"

  # The credential entries of a `policy.applied` event's data (`?` is the data).
  @entries """
  CASE WHEN jsonb_typeof(? -> 'credentials') = 'array' THEN ? -> 'credentials' ELSE '[]'::jsonb END
  """

  # The names of the provider's entries of a run, as described at the top of the module:
  # the names of the run's model keys and the provider row's public id while the row is
  # there; null when there is no name. The arguments: the run's `model_keys` and the
  # provider row's public id (null when the row is gone).
  @names """
  nullif(array_remove(array_append(ARRAY(SELECT k ->> 'name'
                                           FROM jsonb_array_elements(coalesce(?, '[]'::jsonb)) k
                                          WHERE jsonb_typeof(k) = 'object'), ?), NULL), '{}')
  """

  # Whether the run `pe.run_id = r.id` recorded an entry that is the provider's, whose name
  # is the credential or whose hosts include the host, as described at the top of the
  # module. The arguments: the run's id, twice the names of the provider's entries
  # (`provider_names/2`, null for a run read by its endpoint), the host of the run's
  # endpoint, twice more the run's id and that host, then the credential and the host to
  # test.
  @hit """
  EXISTS (
    SELECT 1
      FROM events pe
     CROSS JOIN LATERAL jsonb_array_elements(#{String.replace(@entries, "?", "pe.data")}) ce
     WHERE pe.run_id = ? AND pe.type = '#{@policy_applied}' AND jsonb_typeof(ce) = 'object'
       AND ((ce ->> 'name') = ANY(?)
            OR (? IS NULL
                AND ((ce -> 'hosts') @> to_jsonb(?::text)
                     OR NOT EXISTS (
                       SELECT 1
                         FROM events pe2
                        CROSS JOIN LATERAL jsonb_array_elements(#{String.replace(@entries, "?", "pe2.data")}) ce2
                        WHERE pe2.run_id = ? AND pe2.type = '#{@policy_applied}'
                          AND jsonb_typeof(ce2) = 'object'
                          AND (ce2 -> 'hosts') @> to_jsonb(?::text)))))
       AND (? = (ce ->> 'name') OR (ce -> 'hosts') @> to_jsonb(?::text))
  )
  """

  # The host of a run's recorded endpoint, lower case; null where it has none.
  defmacrop endpoint_host(run) do
    quote do
      fragment(
        "lower(substring((? ->> 'endpoint') from '^[A-Za-z][A-Za-z0-9+.-]*://([^/:\\?#]+)'))",
        unquote(run).provider_api
      )
    end
  end

  # The names of the provider's entries of `run`, computed by `@names`.
  defmacrop provider_names(run, provider) do
    quote do
      fragment(
        unquote(@names),
        unquote(run).model_keys,
        unquote(provider).public_id
      )
    end
  end

  # Whether the row of `credential` and `host` is the provider's: its credential is an
  # entry of the provider, or its host is a recorded host of the provider or the host of
  # the run's endpoint, which holds where no event is kept.
  defmacrop provider_hit(run, provider, credential, host) do
    quote do
      fragment(
        "(coalesce(?, false) OR coalesce(? = ?, false))",
        fragment(
          unquote(@hit),
          unquote(run).id,
          provider_names(unquote(run), unquote(provider)),
          provider_names(unquote(run), unquote(provider)),
          endpoint_host(unquote(run)),
          unquote(run).id,
          endpoint_host(unquote(run)),
          unquote(credential),
          unquote(host)
        ),
        unquote(host),
        endpoint_host(unquote(run))
      )
    end
  end

  # client_reads/4 is `subject`, narrowed as the comment at the top of the module says, for
  # the `kind` of read (`c:Apiary.Edition.client_reads/4`).
  @doc false
  @spec client_reads(Scope.t(), atom, struct | nil, subject) :: subject
        when subject: Ecto.Query.t() | map | nil
  def client_reads(scope, kind, run, subject)

  def client_reads(scope, kind, %Run{provider_chain: "operator"} = run, subject)
      when kind in [:run_events, :run_connections, :run_policy] do
    if hidden_from?(scope), do: narrow(kind, run, subject), else: subject
  end

  def client_reads(scope, kind, nil, subject)
      when kind in [:workspace_connections, :workspace_events] do
    if hidden_from?(scope), do: narrow_workspace(kind, subject), else: subject
  end

  def client_reads(_scope, _kind, _run, subject), do: subject

  # Whether the scope's person is shown a client's runs without the operator's provider:
  # in a client, not through its operator, while the operator owns its clients.
  defp hidden_from?(%Scope{reach: {:operator, _membership}}), do: false

  defp hidden_from?(%Scope{organisation: organisation}),
    do: Flags.operator_infrastructure?() and Tenants.client?(organisation)

  defp hidden_from?(_scope), do: false

  ## A run's records

  defp narrow(:run_policy, _run, nil), do: nil

  defp narrow(:run_policy, run, %{} = policy) do
    entries =
      for %{"name" => name} = entry <- List.wrap(policy[:credentials]), is_binary(name) do
        %{name: name, hosts: strings(entry["hosts"])}
      end

    {names, hosts} = provider(run, entries ++ recorded_entries(run))

    policy
    |> without_credentials(names)
    |> without_hosts(:allow, hosts)
    |> without_hosts(:allow_first, hosts)
    |> without_hosts(:terminated, hosts)
    |> without_tool_hosts(hosts)
  end

  defp narrow(kind, run, query) do
    {names, hosts} = provider(run, recorded_entries(run))
    narrow_query(kind, query, names, hosts)
  end

  defp narrow_query(:run_events, query, names, hosts) do
    from e in query,
      where:
        fragment(
          "NOT (coalesce((? ->> 'credential') = ANY(?), false) OR (? = 'dev.qory.run.egress' AND coalesce((? ->> 'host') = ANY(?), false)))",
          e.data,
          type(^names, {:array, :string}),
          e.type,
          e.data,
          type(^hosts, {:array, :string})
        )
  end

  defp narrow_query(:run_connections, query, names, hosts) do
    from c in query,
      where:
        fragment(
          "NOT (coalesce(? = ANY(?), false) OR coalesce(? = ANY(?), false))",
          c.last_credential,
          type(^names, {:array, :string}),
          c.host,
          type(^hosts, {:array, :string})
        )
  end

  # The names and the hosts of the provider's entries among `entries`, each a recorded
  # `%{name, hosts}`: by the names of the run's model keys and of the provider's row while
  # it is there; with no such name, by the host of the run's endpoint, and, where no entry
  # has it, all of them.
  defp provider(run, entries) do
    names = Enum.uniq(key_names(run) ++ List.wrap(public_id(run.provider_connection_id)))

    matched =
      cond do
        names != [] -> Enum.filter(entries, &(&1.name in names))
        found = by_endpoint(run, entries) -> found
        true -> entries
      end

    names = Enum.uniq(names ++ Enum.map(matched, & &1.name))
    hosts = matched |> Enum.flat_map(& &1.hosts) |> Enum.concat(List.wrap(recorded_host(run)))
    {names, Enum.uniq(hosts)}
  end

  defp by_endpoint(run, entries) do
    case recorded_host(run) do
      nil ->
        nil

      host ->
        case Enum.filter(entries, &(host in &1.hosts)) do
          [] -> nil
          found -> found
        end
    end
  end

  # The host of the run's recorded endpoint, lower case; nil where it has none.
  defp recorded_host(run) do
    with %{"endpoint" => endpoint} when is_binary(endpoint) <- run.provider_api,
         %URI{host: host} when is_binary(host) <- URI.parse(endpoint) do
      String.downcase(host)
    else
      _none -> nil
    end
  end

  # The credential names of the run's model keys.
  defp key_names(%Run{model_keys: keys}) do
    for %{"name" => name} <- List.wrap(keys), is_binary(name), do: name
  end

  # The public id of the provider row `id`; nil where there is no id or the row is gone.
  defp public_id(id) when is_binary(id),
    do: Repo.one(from c in Connection, where: c.id == ^id, select: c.public_id)

  defp public_id(_id), do: nil

  # The credential entries the run's `policy.applied` events recorded, each once.
  defp recorded_entries(%Run{} = run) do
    sql = """
    SELECT DISTINCT ce ->> 'name',
           (SELECT coalesce(jsonb_agg(h #>> '{}'), '[]'::jsonb)
              FROM jsonb_array_elements(
                     CASE WHEN jsonb_typeof(ce -> 'hosts') = 'array' THEN ce -> 'hosts' ELSE '[]'::jsonb END
                   ) h
             WHERE jsonb_typeof(h) = 'string')
      FROM events pe
     CROSS JOIN LATERAL jsonb_array_elements(#{String.replace(@entries, "?", "pe.data")}) ce
     WHERE pe.organisation_id = $1 AND pe.workspace_id = $2 AND pe.run_id = $3
       AND pe.type = $4 AND jsonb_typeof(ce) = 'object' AND jsonb_typeof(ce -> 'name') = 'string'
    """

    %{rows: rows} =
      Repo.query!(sql, [
        Ecto.UUID.dump!(run.organisation_id),
        Ecto.UUID.dump!(run.workspace_id),
        Ecto.UUID.dump!(run.id),
        @policy_applied
      ])

    for [name, hosts] <- rows, do: %{name: name, hosts: strings(hosts)}
  end

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_other), do: []

  # The policy without the credential entries named in `names`, its count lowered by the
  # distinct entries (name and argument) taken out.
  defp without_credentials(%{credentials: [_ | _] = entries} = policy, names) do
    {removed, kept} = Enum.split_with(entries, &(&1["name"] in names))
    taken = removed |> Enum.uniq_by(&{&1["name"], &1["argument"]}) |> length()

    lower(%{policy | credentials: kept}, :credentials_count, taken)
  end

  defp without_credentials(policy, _names), do: policy

  defp without_hosts(%{} = policy, key, hosts) do
    case Map.get(policy, key) do
      [_ | _] = listed when hosts != [] ->
        kept = Enum.reject(listed, &(&1 in hosts))

        policy
        |> Map.put(key, kept)
        |> lower(:"#{key}_count", length(listed) - length(kept))

      _none ->
        policy
    end
  end

  # The tools of the policy, each without the hosts in `hosts`. The tools are kept, and so
  # is the count of them.
  defp without_tool_hosts(%{tools: [_ | _] = tools} = policy, hosts) when hosts != [] do
    kept =
      for tool <- tools do
        case tool do
          %{"hosts" => listed} when is_list(listed) ->
            %{tool | "hosts" => Enum.reject(listed, &(&1 in hosts))}

          _other ->
            tool
        end
      end

    %{policy | tools: kept}
  end

  defp without_tool_hosts(policy, _hosts), do: policy

  defp lower(policy, key, by) do
    case Map.get(policy, key) do
      count when is_integer(count) -> Map.put(policy, key, max(count - by, 0))
      _none -> policy
    end
  end

  ## The workspace's rows

  # The rows of runs of the operator's chain are kept unless their credential is the name
  # of one of the run's model keys, the provider row's or an entry's of the provider, or
  # their host is one of its hosts (a left join: a run whose provider row is gone is read by
  # the names of its model keys, and with none, by its recorded endpoint).
  defp narrow_workspace(:workspace_connections, query) do
    from [c, r] in query,
      left_join: p in Connection,
      on: p.id == r.provider_connection_id,
      where:
        not fragment(
          "coalesce(? = 'operator' AND (coalesce(? = ANY(?), false) OR coalesce(?, false)), false)",
          r.provider_chain,
          c.last_credential,
          provider_names(r, p),
          provider_hit(r, p, c.last_credential, c.host)
        )
  end

  defp narrow_workspace(:workspace_events, query) do
    from [e, r] in query,
      left_join: p in Connection,
      on: p.id == r.provider_connection_id,
      where:
        not fragment(
          "coalesce(? = 'operator' AND (coalesce((? ->> 'credential') = ANY(?), false) OR coalesce(?, false)), false)",
          r.provider_chain,
          e.data,
          provider_names(r, p),
          provider_hit(
            r,
            p,
            fragment("? ->> 'credential'", e.data),
            fragment("CASE WHEN ? = 'dev.qory.run.egress' THEN ? ->> 'host' END", e.type, e.data)
          )
        )
  end
end
