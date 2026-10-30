defmodule Apiary.Runs.AttachImageTest do
  # The image an attach gives a run of the queue that its claim read
  # (`runs.configured_image`): read again through the registry's place of the run's
  # organisation, so a run claimed before that check with an image elsewhere starts in
  # the pool's default image.
  use Apiary.DataCase, async: true

  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Runs.{Attach, Run}

  @moduletag needs: [:factory, :registry]

  @digest String.duplicate("4d", 32)

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  # An explore run claimed and handed over, its `configured_image` set to `image` as a
  # claim would have set it, then attached by its gateway: the run as stored and the
  # attach's answer.
  defp attached!(ctx, image) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{registered: registered, run_code: code} = dispatched!(ctx.key)

    registered |> Ecto.Changeset.change(configured_image: image) |> Repo.update!()

    {:ok, attach} = Attach.parse(attach_body(redeemed_run_key!(code)))
    {key, _seed} = ctx.gateway_key

    {:ok, answer} =
      Attach.attach(key, registered.node_run_id, attach, %{
        forager_version: "0.7.0",
        instance_id: instance_id()
      })

    {Repo.get!(Run, registered.id), Jason.decode!(answer.settings)}
  end

  test "an image of another registry is dropped: the run starts in the pool's default image",
       ctx do
    {run, document} = attached!(ctx, "registry.other.example/acme/shop-env@sha256:" <> @digest)
    assert run.configured_image == nil
    refute Map.has_key?(document, "image")
  end

  test "another organisation's image is dropped", ctx do
    other = sign_up_fixture().scope.organisation.id
    {run, document} = attached!(ctx, registry_image(other, @digest))
    assert run.configured_image == nil
    refute Map.has_key?(document, "image")
  end

  test "the organisation's image is given", ctx do
    image = registry_image(ctx.scope.organisation.id, @digest)
    {run, document} = attached!(ctx, image)
    assert run.configured_image == image
    assert document["image"] == image
  end
end
