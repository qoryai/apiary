defmodule Apiary.ArtifactsAccessStub do
  @moduledoc """
  Registers the access actions `Apiary.Artifacts` checks, `artifact.write` for members and
  `artifact_type.edit` for owners and admins, for a test, until the piece that lists them
  in `Apiary.Access` lands. An action `Apiary.Access` lists already is left as it is, so
  the tests run the same once it does; then this module goes.

  The actions go into the registry `Apiary.Access` keeps in `:persistent_term`, which the
  whole node reads: a module that calls `register/1` is not async, and the registry is put
  back as the test ends.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Apiary.Access
  alias Apiary.Access.Action

  @doc "Registers the two actions for the test: for `setup`."
  def register(_context) do
    original = :persistent_term.get(Access, nil)
    known = Access.actions()

    stubs =
      Enum.reject(
        [
          Action.new(:"artifact.write", "store a version of a work item's artifact",
            feature: :factory,
            roles: [:owner, :admin, :member]
          ),
          Action.new(:"artifact_type.edit", "edit the workspace's artifact types",
            feature: :factory,
            roles: [:owner, :admin]
          )
        ],
        &(&1.name in known)
      )

    if stubs != [] do
      registry =
        Access.build_registry(Apiary.Edition.actions() ++ stubs, Apiary.Edition.roles())

      :persistent_term.put(Access, registry)

      on_exit(fn ->
        if original,
          do: :persistent_term.put(Access, original),
          else: :persistent_term.erase(Access)
      end)
    end

    :ok
  end
end
