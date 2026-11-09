defmodule Apiary.Dispatches.Built do
  @moduledoc false

  # The image a prebuild built, as its run reports it in the run's record: the event
  # `dev.qory.run.built` (Forager's `events/run.built.schema.json`), with `image`, pinned
  # by its digest, its `size`, the `commit` it was built from and the `environment_ref`
  # the build read. `record/1` stores it, once a projection folded the event
  # (`Apiary.Runs.Projector`), in a separate transaction after the projection's passes
  # committed.
  #
  # ## Which run's image is stored
  #
  # Only a run registered for a run of the queue for the step `prebuild`
  # (`Apiary.Dispatches.DispatchRun`) that was handed over: `handed_over` or `ended`,
  # whatever its end cause. So an event that comes after the run's exit ended its run of
  # the queue, or after the lost-run check ended it, is stored as one that comes before.
  # The event of any other run, a run a node registered itself or a run of the queue for
  # another step, is stored with the run's other events and records nothing.
  #
  # Of the run's events of that type, the one with the lowest sequence counts: the
  # contract has one at most. Its data is read as untrusted, as every event's is
  # (`Apiary.Runs.Fold`): `image` as the provisioner contract's `$defs/image`, a
  # lower-case name of at most 255 characters, `@sha256:` and 64 lower-case hexadecimal
  # digits; `size` an integer from 1 to 2^53 - 1; `commit` 40 or 64 lower-case
  # hexadecimal characters; `environment_ref` 1 to 200 characters with no U+0000; and
  # `environment_image`, when the event has it, of the form of `image`. An event that
  # breaks one of them records nothing.
  #
  # ## Where the image is
  #
  # The claim sent the prebuild its destinations in the registry, in the run's documents,
  # which the registered run keeps as they were sent (`runs.run_documents`,
  # `Apiary.Dispatches.Handover`). The image's place, its name before `@sha256:`, must be
  # exactly the documents' `image_destination`. An `environment_image` the event has must
  # be at exactly the documents' `environment_destination`, or be exactly the documents'
  # `environment_image`, the one the build started from. An image elsewhere, another
  # organisation's, another instance's, another registry's or a path that only starts
  # with the destination, records nothing, and is logged as a warning with the run's
  # public id and the member, never the image. So is a report of a run whose documents
  # have no destination: one registered before the claim sent them. The destinations are
  # read from the documents and never made again: the environment image's name depends
  # on the run configuration in force (`Apiary.Registry.Names.environment_key/5`), which
  # may change between the claim and the report.
  #
  # ## What is stored
  #
  # The build is recorded on the environment record of the prebuild's pool and collection
  # as the provisioner's report of the image stored it before that report left the
  # provisioner contract (`Apiary.Environments.record_build/4`): the image, its size, its
  # commit, the `environment_ref` reported, as it is, `built_at`, the target it was built
  # for, the registered run's target, read from its registration labels by its
  # workspace's domain (`Apiary.Lingo.Domain.target/2`), the `environment_ref` the
  # prebuild was queued for (`built_ref`), and when it was queued for it. The last failure
  # and `lost_ref` are cleared, and nothing is queued. Once the transaction commits, the
  # workspace's queue is told (`Apiary.Dispatches.broadcast/1`): a claim that listens
  # there takes a run that waited for that image (`Apiary.Environments.held/1`).
  #
  # A build whose prebuild took its `environment_ref` before the prebuild that made the
  # record's image took its (`Apiary.Environments.newer_build?/2`) leaves the record as it
  # is, and so does the build already on the record: the same image, made by the same
  # prebuild (`Apiary.Environments.built_by?/2`). So a second call writes nothing again.
  # A projection calls it only in the pass that folds the report that counts, and a
  # rebuild of the run's projection never does (`Apiary.Runs.Projector`): an image
  # cleared because the registry lost it (`Apiary.Environments.forget_image/3`) is not
  # stored again.
  #
  # **Locks.** The environment record of the prebuild's pool and collection, `FOR UPDATE`
  # (`Apiary.Environments.lock_record/2`), from the run of the queue read without a lock,
  # for its columns that never change, as the end of a prebuild holds it last
  # (`Apiary.Dispatches.RunEnd`): so the store and the end of the same prebuild take
  # turns at the record. Nothing of the queue is locked.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Environments, Repo}
  alias Apiary.Adapters.Wire, as: AdapterWire
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Lingo.Domain
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Event, Run}

  @built "dev.qory.run.built"
  @prebuild DispatchRun.prebuild()
  @max_size 9_007_199_254_740_991
  @max_ref 200
  # The provisioner contract's `$defs/image`, whose name is at most 255 characters: with
  # the digest's 72 after it, at most 327 in all, held before the pattern is matched.
  @image ~r/\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?::[0-9]{1,5})?\/)?[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*@sha256:[0-9a-f]{64}\z/
  @max_image_bytes 327
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  # type/0 is the event's type.
  @doc false
  @spec type() :: String.t()
  def type, do: @built

  # record/1 stores the image the prebuild `run` reported (the moduledoc): `:recorded`
  # when the record was written, `:kept` when the record already had that build or a
  # newer one, `:refused` for a report that fails its check (`check/2`), and `:none`
  # when the run has no such event.
  @doc false
  @spec record(Run.t()) :: :recorded | :kept | :refused | :none
  def record(%Run{id: run_id, public_id: public_id, dispatch_run_id: dispatch_run_id})
      when is_binary(dispatch_run_id) do
    {:ok, recorded} =
      Repo.transact(fn ->
        with {:ok, data} <- reported(run_id),
             run = Repo.get!(Run, run_id),
             {:ok, dispatch_run, build} <- checked(run, data) do
          held = Environments.lock_record(dispatch_run.pool_id, dispatch_run.source_collection_id)
          {:ok, {store(held, dispatch_run, run, build), dispatch_run}}
        else
          :none ->
            {:ok, :none}

          {:refused, why} ->
            warn(public_id, why)
            {:ok, :refused}
        end
      end)

    case recorded do
      {:recorded, %DispatchRun{workspace_id: workspace_id}} ->
        Apiary.Dispatches.broadcast([workspace_id])
        :recorded

      {kept, %DispatchRun{}} ->
        kept

      other ->
        other
    end
  end

  def record(%Run{id: run_id}) do
    case reported(run_id) do
      {:ok, _data} -> :refused
      :none -> :none
    end
  end

  @typedoc """
  Why a report fails its check, with the values a reader needs to see why:

    * `:not_prebuild`: the run is not a prebuild handed over, with a pool and a
      collection.
    * `{:form, member}`: the event's `member` breaks its rules, the first of `image`,
      `size`, `commit`, `environment_ref` and `environment_image` that does.
    * `{:image_place, reported, expected}`: the image's place, its name before
      `@sha256:`, is `reported`, not the run's `image_destination`, `expected`.
    * `{:environment_image, reported, {:destination, place}}`: the environment image's
      place is `reported`, not the run's `environment_destination`, `place`.
    * `{:environment_image, reported, {:image, image}}`: the environment image is
      `reported`, not the run's `environment_image`, `image`, the one the build started
      from.
    * `:no_destination`: the run's documents have no destination.

  A reported value passed the event's rules, so it is an image or a place of the form of
  the provisioner contract's `$defs/image`.
  """
  @type refusal ::
          :not_prebuild
          | {:form, String.t()}
          | {:image_place, String.t(), String.t()}
          | {:environment_image, String.t(), {:destination | :image, String.t()}}
          | :no_destination

  # check/2 is the check of `data`, the data of the report of `run`, that `record/1`
  # makes before it stores the image (the moduledoc), the one check both use: `:ok`, or
  # `{:refused, why}`. It reads the run's run of the queue, without a lock, the data and
  # the run's documents, and logs nothing.
  @doc false
  @spec check(Run.t(), map) :: :ok | {:refused, refusal}
  def check(%Run{} = run, data) do
    case checked(run, data) do
      {:ok, _dispatch_run, _build} -> :ok
      {:refused, _why} = refused -> refused
    end
  end

  # The run's run of the queue and the build, or why the report is refused.
  defp checked(%Run{dispatch_run_id: id} = run, data) do
    with %DispatchRun{} = dispatch_run <- is_binary(id) && prebuild(id),
         {:ok, build} <- build(data),
         :ok <- placed(run, build) do
      {:ok, dispatch_run, build}
    else
      falsy when falsy in [nil, false] -> {:refused, :not_prebuild}
      {:error, member} -> {:refused, {:form, member}}
      {:refused, _why} = refused -> refused
    end
  end

  # The data of the run's event of this type with the lowest sequence, or :none.
  defp reported(run_id) do
    case Repo.one(
           from e in Event,
             where: e.run_id == ^run_id and e.type == @built,
             order_by: [asc: e.sequence],
             limit: 1,
             select: e.data
         ) do
      nil -> :none
      data -> {:ok, data}
    end
  end

  # The run of the queue `id` when it is a prebuild that was handed over, read without a
  # lock; nil otherwise.
  defp prebuild(id) do
    Repo.one(
      from d in DispatchRun,
        where: d.id == ^id and d.step == ^@prebuild,
        where: fragment("? IN ('handed_over', 'ended')", d.state),
        where: not is_nil(d.pool_id) and not is_nil(d.source_collection_id)
    )
  end

  # The event's data held to its rules (the moduledoc): `{:ok, build}`, or
  # `{:error, member}` for the first member that breaks them. The build's
  # `environment_image` is nil where the event has none.
  defp build(%{} = data) do
    with {:ok, image} <- member(data, "image", &image?/1),
         {:ok, size} <- member(data, "size", &(is_integer(&1) and &1 in 1..@max_size//1)),
         {:ok, commit} <- member(data, "commit", &(is_binary(&1) and Regex.match?(@commit, &1))),
         {:ok, ref} <-
           member(
             data,
             "environment_ref",
             &(is_binary(&1) and AdapterWire.text?(&1, 1, @max_ref))
           ),
         {:ok, environment_image} <- environment_image(data) do
      {:ok,
       %{
         image: image,
         size: size,
         commit: commit,
         environment_ref: ref,
         environment_image: environment_image
       }}
    end
  end

  # Data that is no object has none of the members, so its first, `image`, breaks them.
  defp build(_data), do: {:error, "image"}

  defp member(data, member, valid?) do
    value = data[member]
    if valid?.(value), do: {:ok, value}, else: {:error, member}
  end

  defp environment_image(%{"environment_image" => _image} = data),
    do: member(data, "environment_image", &image?/1)

  defp environment_image(_data), do: {:ok, nil}

  defp image?(image),
    do:
      is_binary(image) and byte_size(image) <= @max_image_bytes and
        Regex.match?(@image, image)

  # :ok when the build's images are where the run's documents sent them (the moduledoc),
  # `{:refused, why}` otherwise.
  defp placed(%Run{} = run, build) do
    case destinations(run) do
      {:ok, image_destination, environment} ->
        cond do
          place(build.image) != image_destination ->
            {:refused, {:image_place, place(build.image), image_destination}}

          not environment_placed?(build.environment_image, environment) ->
            {:refused,
             {:environment_image, reported(build.environment_image, environment), environment}}

          true ->
            :ok
        end

      :error ->
        {:refused, :no_destination}
    end
  end

  # The destinations in the documents the claim sent the run: `{:ok, image_destination,
  # environment}`, with `{:destination, place}` or `{:image, image}`, or :error.
  defp destinations(%Run{run_documents: documents}) when is_binary(documents) do
    case Jason.decode(documents) do
      {:ok, %{"image_destination" => image_destination} = decoded}
      when is_binary(image_destination) ->
        case decoded do
          %{"environment_destination" => place} when is_binary(place) ->
            {:ok, image_destination, {:destination, place}}

          %{"environment_image" => image} when is_binary(image) ->
            {:ok, image_destination, {:image, image}}

          _neither ->
            :error
        end

      _no_destination ->
        :error
    end
  end

  defp destinations(%Run{}), do: :error

  # What the run reported of its environment image, as the documents set it: its place
  # for a destination, the image itself for the image the build started from.
  defp reported(image, {:destination, _place}), do: place(image)
  defp reported(image, {:image, _sent}), do: image

  defp environment_placed?(nil, _environment), do: true
  defp environment_placed?(image, {:destination, place}), do: place(image) == place
  defp environment_placed?(image, {:image, sent}), do: image == sent

  # An image's place: its name before `@sha256:`. The image matched `@image`, so its name
  # has no `@`.
  defp place(image), do: image |> String.split("@", parts: 2) |> hd()

  # A report refused for where its images are is logged with the run's public id and the
  # member, never the image.
  defp warn(public_id, {:image_place, _reported, _expected}),
    do: warn(public_id, "image", "is not at the run's image_destination")

  defp warn(public_id, {:environment_image, _reported, _expected}),
    do: warn(public_id, "environment_image", "is not the environment image the run was sent")

  defp warn(public_id, :no_destination),
    do:
      warn(public_id, "image", "cannot be checked: the run's documents have no image_destination")

  defp warn(_public_id, :not_prebuild), do: :ok
  defp warn(_public_id, {:form, _member}), do: :ok

  defp warn(public_id, member, why) do
    Logger.warning(
      "a prebuild's report was not recorded: its #{member} #{why} (run #{public_id})"
    )
  end

  # The build recorded on `held`, the record locked first, unless the record has a newer
  # build or this one already.
  defp store(held, dispatch_run, run, build) do
    if Environments.newer_build?(held, dispatch_run) or
         (Environments.built_by?(held, dispatch_run) and held.image == build.image) do
      :kept
    else
      :ok =
        Environments.record_build(dispatch_run, build, built_target(run), Apiary.Dispatches.now())

      :recorded
    end
  end

  # The registered run's target, read from its registration labels by its workspace's
  # domain: the target of its handover.
  defp built_target(%Run{workspace_id: workspace_id, registration_labels: labels}) do
    case Domain.target(Repo.get!(Workspace, workspace_id), labels) do
      {:ok, target} -> target
      :none -> nil
    end
  end
end
