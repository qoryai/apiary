defmodule Apiary.Dispatches.InputsTakeInCommentTest do
  # A comment a member wrote at take in reaches Explore's input like any comment of the
  # ticket (`Apiary.Dispatches.Inputs.explore/4`): in its place by time, by the member's
  # short name, a person, and the input still keeps to its schema.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{ExploreInputsSchema, Repo, WorkItems}
  alias Apiary.Dispatches.{DispatchRun, Inputs}
  alias Apiary.Sources.Comment

  @moduletag needs: :factory

  defp inputs(work_item) do
    run = Repo.one!(from r in DispatchRun, where: r.work_item_id == ^work_item.id)

    {:ok, inputs} =
      Inputs.explore(work_item, run, %{
        domain: "software",
        target: %{system: work_item.target_system, path: work_item.target_path}
      })

    inputs |> Jason.encode!() |> Jason.decode!()
  end

  test "has the take in's comment, by the member, after the comments before it" do
    %{scope: scope} = sign_up_fixture()
    ticket = backlog_ticket_fixture(scope)
    earlier = DateTime.add(DateTime.utc_now(:second), -3600, :second)

    Repo.insert!(%Comment{
      organisation_id: scope.organisation.id,
      item_id: ticket.id,
      external_ref: "c1",
      url: "https://forge.example.com/acme/shop/issues/12#c1",
      author_name: "Robin Example",
      author_kind: :person,
      body: "It fails at checkout.",
      body_format: "markdown",
      source_created_at: earlier,
      source_updated_at: earlier
    })

    {:ok, work_item} =
      WorkItems.take_in(scope, ticket.public_id, %{comment: "Start with the basket."})

    inputs = inputs(work_item)
    name = scope.user.email |> String.split("@") |> hd()

    assert [
             %{"by" => %{"name" => "Robin Example", "kind" => "person"}},
             %{"by" => %{"name" => ^name, "kind" => "person"}, "body" => body, "at" => at}
           ] = inputs["comments"]

    assert body == "Start with the basket."
    assert name == Inputs.person_name(scope.user.id)

    [%Comment{source_created_at: written}] =
      Repo.all(from c in Comment, where: not is_nil(c.comment_id))

    assert at == DateTime.to_iso8601(written)
    assert ExploreInputsSchema.validate(inputs) == :ok
  end
end
