defmodule Apiary.Registry.RunAccess do
  @moduledoc false

  # What a run may use in the private image registry, with the `registry` feature, which
  # the documentation leaves out: the names its tokens grant (`rights/1`) and what its
  # run configuration gains (`member/1`).
  #
  # **Which runs.** A run through a gateway (`Apiary.Runs.Run.through_gateway?/1`), on an
  # instance with the feature on: only its gateway fetches the credential's value, with
  # the secrets request. Any other run gains nothing, and its tokens grant nothing.
  #
  # **The names.** A run with a target has its target's image name
  # (`Apiary.Registry.Names.target_name/3`). A build, a run of a workspace's queue for the
  # step `prebuild` (`Apiary.Policy.ComposedConfiguration.prebuild?/1`), also has the
  # name of the environment image for its key (`environment_key/2`).
  #
  # **The rights.** A run that is not a build may pull its target's image name. A build
  # may push and pull its target's image name, and push and pull the environment image's
  # name while that image does not exist (`environment_exists?/2`), then pull it alone,
  # the image it builds on. Every run may also pull what `Apiary.Registry.Grant` grants
  # every run, under `shared/` and `upstream/`.
  #
  # **The environment image exists** when an environment record of the run's
  # organisation (`Apiary.Environments.Record`) has an `image` under the name in the
  # registry, `<QORY_REGISTRY>/<name>@…`. No build reports an environment image yet, so
  # until one does, no record has one, and a build may push its environment image.
  #
  # **What the run configuration gains** (`member/1`):
  #
  #   * the host credential `registry`: `hosts`, the host of the instance's public URL;
  #     `paths`, `/registry/token`; `auth`, `basic` with the run's public id as the user
  #     name. The document has no value: the secrets request seals it
  #     (`Apiary.Registry.Credential`);
  #   * path rules for the registry's host, without a credential, in the
  #     `security_policy`'s `egress.paths`, which a gateway matches against the request's
  #     path alone, without its query and whatever its method, each rule whole or up to a
  #     final `*`: `/v2/`, `/v2/shared/*` and `/v2/upstream/*` for every run; for its
  #     target's image name `T`, `/v2/T/manifests/sha256:*`, `/v2/T/blobs/*` and
  #     `/v2/T/referrers/*` for a run that is not a build; for a build, those three and
  #     `/v2/T/manifests/<run id>`, and the same four for its environment image's name
  #     `E`, whether it may push there or only pull. `<run id>` is the run's id as its
  #     node gave it, the tag a build pushes; a push of an image index puts its child
  #     manifests by digest, under `manifests/sha256:`. The token stays the limit: a path
  #     rule cannot tell a push from a pull, so `E`'s rules stay the same when its image
  #     comes to exist, and the run configuration with them;
  #   * the instance's host and the registry's host, in `egress.allow` and
  #     `egress.allow_first`, as a model provider's hosts are, and the path rule
  #     `/registry/token` for the instance's host (`instance_host`), unless its document
  #     allowed the host before (`Apiary.Policy.ComposedConfiguration`). Under enforce, a
  #     gateway already denies each path of that host that matches neither the
  #     credential's path nor the document's rules for the host; under observe, a run
  #     reaches every path of that host, and the gateway sends the registry credential
  #     only with requests to `/registry/token`.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Features, InstanceConfig, Policy, Registry, Repo}
  alias Apiary.Dispatches.{DispatchRun, MachinesFile}
  alias Apiary.Environments.Record
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Policy.{ComposedConfiguration, RunConfiguration}
  alias Apiary.Registry.{Credential, Names}
  alias Apiary.Runs.{ProviderCredential, Run, Target}

  @typedoc "What a run's run configuration gains: its credential, hosts and path rules."
  @type member :: %{
          entry: Jason.OrderedObject.t(),
          hosts: [String.t()],
          instance_host: String.t(),
          registry_host: String.t(),
          paths: [String.t()]
        }

  @doc false
  # applies?/1 is whether `run` has registry access: the feature is on, and the run goes
  # through a gateway.
  @spec applies?(map | nil) :: boolean
  def applies?(%{public_id: public_id} = run) when is_binary(public_id),
    do: Features.on?(:registry) and Run.through_gateway?(run)

  def applies?(_run), do: false

  @doc false
  # member/1 is what `run`'s run configuration gains, nil for a run without registry
  # access.
  @spec member(map | nil) :: member | nil
  def member(run) do
    if applies?(run) do
      names = names(run)

      %{
        entry: entry(run),
        hosts: [instance_host(), Registry.host()],
        instance_host: instance_host(),
        registry_host: Registry.host(),
        paths: paths(run, names)
      }
    end
  end

  @doc false
  # rights/1 is the exact names `run` has, with their actions (`Apiary.Registry.Grant`).
  @spec rights(Run.t()) :: %{String.t() => [String.t()]}
  def rights(%Run{} = run) do
    if applies?(run) do
      case names(run) do
        %{target: nil} ->
          %{}

        %{build?: false, target: target} ->
          %{target => ["pull"]}

        %{build?: true, target: target, environment: nil} ->
          %{target => ["pull", "push"]}

        %{build?: true, target: target, environment: environment, push_environment?: push?} ->
          %{
            target => ["pull", "push"],
            environment => if(push?, do: ["pull", "push"], else: ["pull"])
          }
      end
    else
      %{}
    end
  end

  @doc false
  # token_path/0 is the path of the token route. Under enforce, with the feature alone,
  # it is the one path of the instance's host a run reaches; under observe, a run
  # reaches every path of that host.
  @spec token_path() :: String.t()
  def token_path, do: "/registry/token"

  @doc false
  # instance_host/0 is the host of the instance's public URL, the host the run's
  # credential is set on.
  @spec instance_host() :: String.t()
  def instance_host, do: URI.parse(ApiaryWeb.Endpoint.url()).host

  # The run's names: its target's image name, nil for a run without a target; whether it
  # is a build; and for a build, its environment image's name and whether it may push
  # there.
  defp names(run) do
    target_id = target_id(run)
    target = target_name(run, target_id)
    build? = not is_nil(target) and match?(%Run{}, run) and ComposedConfiguration.prebuild?(run)

    if build? do
      environment = environment_name(run, target_id)

      %{
        target: target,
        build?: true,
        environment: environment,
        push_environment?: is_binary(environment) and not environment_exists?(run, environment)
      }
    else
      %{target: target, build?: false}
    end
  end

  # The run's target, as `Apiary.Policy.Serving` reads it: for a run that registered,
  # the target row its registration's labels name by the workspace's domain, whatever its
  # events say; for any other run, the target its row has. Nil for none.
  defp target_id(%{registration_labels: %{} = labels, workspace_id: workspace_id}) do
    with %Workspace{} = workspace <- Repo.get(Workspace, workspace_id),
         {:ok, %{system: system, path: path}} <- Domain.target(workspace, labels) do
      Repo.one(
        from t in Target,
          where: t.workspace_id == ^workspace_id and t.system == ^system and t.path == ^path,
          select: t.id
      )
    else
      _none -> nil
    end
  end

  defp target_id(%{target_id: target_id}) when is_binary(target_id), do: target_id
  defp target_id(_run), do: nil

  defp target_name(_run, nil), do: nil

  defp target_name(run, target_id) do
    case Repo.one(from t in Target, where: t.id == ^target_id, select: t.public_id) do
      public_id when is_binary(public_id) ->
        with instance when is_binary(instance) <- InstanceConfig.registry_instance(),
             do: Names.target_name(instance, run.organisation_id, public_id)

      nil ->
        nil
    end
  end

  # The environment image's name of a build: nil where its run of the queue is gone.
  defp environment_name(%{dispatch_run_id: id} = run, target_id) when is_binary(id) do
    case Repo.one(
           from d in DispatchRun,
             join: p in Node,
             on: p.id == d.pool_id,
             where: d.id == ^id,
             select: {d.environment_ref, p.public_id}
         ) do
      {ref, pool} when is_binary(ref) ->
        key = environment_key(run, target_id, ref, machine(run) || pool)

        with instance when is_binary(instance) <- InstanceConfig.registry_instance(),
             do: Names.environment_name(instance, run.organisation_id, key)

      _none ->
        nil
    end
  end

  defp environment_name(_run, _target_id), do: nil

  # `<key>` for `run` (`Apiary.Registry.Names.environment_key/5`): its organisation, the
  # `environment_ref` it builds, its machine kind, and the hosts of the run configuration
  # in force for its target `target_id`: the `egress.allow` and `egress.allow_first` of
  # its `security_policy`, and the hosts of its credentials, the model provider's and the
  # registry credential's.
  defp environment_key(run, target_id, environment_ref, machine) do
    egress =
      case Policy.in_force(run.organisation_id, run.workspace_id, target_id) do
        {:ok, %RunConfiguration{document: document}} -> egress_hosts(document)
        {:error, _unmanaged} -> []
      end

    provider =
      case ProviderCredential.for_run(run) do
        {:ok, %{hosts: hosts}} -> hosts
        _none -> []
      end

    Names.environment_key(
      run.organisation_id,
      environment_ref,
      machine,
      egress ++ provider,
      provider ++ [instance_host()]
    )
  end

  defp egress_hosts(document) do
    case Jason.decode!(document) do
      %{"security_policy" => %{"egress" => egress}} when is_map(egress) ->
        List.wrap(egress["allow"]) ++ List.wrap(egress["allow_first"])

      _none ->
        []
    end
  end

  # The machine kind the machines file sets for the run's workspace, nil for none.
  defp machine(run) do
    case Repo.one(
           from w in Workspace,
             join: o in Organisation,
             on: o.id == w.organisation_id,
             where: w.id == ^run.workspace_id,
             select: {o.slug, w.slug}
         ) do
      {organisation, workspace} -> MachinesFile.machine(organisation, workspace)
      nil -> nil
    end
  end

  @doc false
  # environment_exists?/2 is whether an environment record of `run`'s organisation has
  # an image under `name` in the registry.
  @spec environment_exists?(map, String.t()) :: boolean
  def environment_exists?(run, name) do
    prefix = "#{Registry.service()}/#{name}@"

    Repo.exists?(
      from e in Record,
        where: e.organisation_id == ^run.organisation_id and like(e.image, ^"#{prefix}%")
    )
  end

  defp entry(run) do
    Jason.OrderedObject.new([
      {"name", Credential.name()},
      {"hosts", [instance_host()]},
      {"paths", [token_path()]},
      {"auth", Jason.OrderedObject.new([{"scheme", "basic"}, {"username", run.public_id}])}
    ])
  end

  defp paths(run, names) do
    base = ["/v2/", "/v2/shared/*", "/v2/upstream/*"]

    named =
      case names do
        %{target: nil} ->
          []

        %{build?: false, target: target} ->
          [
            "/v2/#{target}/manifests/sha256:*",
            "/v2/#{target}/blobs/*",
            "/v2/#{target}/referrers/*"
          ]

        %{build?: true, target: target, environment: environment} ->
          build_paths(target, run) ++
            if(is_binary(environment), do: build_paths(environment, run), else: [])
      end

    base ++ named
  end

  defp build_paths(name, run),
    do: [
      "/v2/#{name}/manifests/#{run.node_run_id}",
      "/v2/#{name}/manifests/sha256:*",
      "/v2/#{name}/blobs/*",
      "/v2/#{name}/referrers/*"
    ]
end
