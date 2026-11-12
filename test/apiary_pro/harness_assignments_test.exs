defmodule ApiaryPro.HarnessAssignmentsTest do
  # An operator's assignments of harness sources to its clients, and the edition's answer to the
  # core's rule for the links of a harness source (`Apiary.Harnesses.allowed?/3`, which
  # asks `ApiaryPro.Edition.harness_source_allowed?/3` after the core's checks refuse). The
  # tests go through the core's function.
  use Apiary.DataCase, async: true

  import ApiaryPro.OperatorsFixtures

  alias Apiary.Harnesses
  alias Apiary.Stacks
  alias ApiaryPro.{Edition, Flags, HarnessAssignments}
  alias ApiaryPro.HarnessAssignments.Assignment

  @moduletag with_features: Apiary.Features.all()

  @git "https://code.example.com/team/stacks"
  @base %{"git" => @git, "ref" => "main", "path" => "core"}
  @export %{"git" => @git, "ref" => "main", "stack" => "web"}
  @module %{"git" => @git, "ref" => "main", "module" => "lint"}
  @root %{"git" => @git, "ref" => "main"}

  # An operator with two clients, a second operator with one client, and a client's owner,
  # made while the flag is off, then the flag on.
  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    second = client_fixture(operator.scope)
    elsewhere = operator_fixture()
    other_client = client_fixture(elsewhere.scope)

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      client: client,
      second: second,
      elsewhere: elsewhere,
      other_client: other_client
    }
  end

  defp oid(ctx), do: ctx.operator.organisation.id
  defp cid(client), do: client.organisation.id

  defp assign!(operator, client, source) do
    {:ok, assignment} = HarnessAssignments.assign(operator.organisation.id, cid(client), source)
    assignment
  end

  defp allowed?(run, owner, source), do: Harnesses.allowed?(run, owner, source)

  describe "an assigned source" do
    test "passes, whatever it is narrowed to", ctx do
      for source <- [@base, @export, @module, @root] do
        assign!(ctx.operator, ctx.client, source)
      end

      for source <- [@base, @export, @module, @root] do
        assert allowed?(cid(ctx.client), oid(ctx), source)
        assert Edition.harness_source_allowed?(cid(ctx.client), oid(ctx), source)
      end
    end

    test "is read from the database now: a row is no answer by itself", ctx do
      assign!(ctx.operator, ctx.client, @base)
      assert allowed?(cid(ctx.client), oid(ctx), @base)

      {:ok, _assignment} = HarnessAssignments.unassign(oid(ctx), cid(ctx.client), @base)
      refute allowed?(cid(ctx.client), oid(ctx), @base)
    end
  end

  describe "a source that no assignment covers exactly is refused" do
    setup ctx do
      assign!(ctx.operator, ctx.client, @base)
      :ok
    end

    test "the same path at another ref", ctx do
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "ref" => "next"})
    end

    test "another path in the same repository", ctx do
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "path" => "other"})
    end

    test "another repository", ctx do
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "git" => @git <> "-two"})
    end

    test "a different narrowing key, with the same value or none", ctx do
      refute allowed?(cid(ctx.client), oid(ctx), %{
               "git" => @git,
               "ref" => "main",
               "stack" => "core"
             })

      refute allowed?(cid(ctx.client), oid(ctx), %{
               "git" => @git,
               "ref" => "main",
               "module" => "core"
             })

      refute allowed?(cid(ctx.client), oid(ctx), @root)

      source = Map.put(@base, "stack", "core")
      refute allowed?(cid(ctx.client), oid(ctx), source)
    end

    test "a root assignment covers the root alone, not what is in it", ctx do
      assign!(ctx.operator, ctx.client, @root)

      assert allowed?(cid(ctx.client), oid(ctx), @root)
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "path" => "other"})
      refute allowed?(cid(ctx.client), oid(ctx), @export)
    end

    test "the texts compared as written: no case, no .git, no trailing slash", ctx do
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "git" => String.upcase(@git)})
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "git" => @git <> ".git"})
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "git" => @git <> "/"})
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "path" => "Core"})
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "path" => "core/"})
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "ref" => "MAIN"})
    end

    test "a source with another key or a value that is no text", ctx do
      refute allowed?(cid(ctx.client), oid(ctx), Map.put(@base, "name", "x"))
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "path" => 1})
      refute allowed?(cid(ctx.client), oid(ctx), Map.delete(@base, "ref"))
      refute allowed?(cid(ctx.client), oid(ctx), %{})
    end

    test "another client of the same operator", ctx do
      refute allowed?(cid(ctx.second), oid(ctx), @base)
    end

    test "no organisation, no owner and no map", ctx do
      refute Edition.harness_source_allowed?(cid(ctx.client), oid(ctx), nil)
      refute Edition.harness_source_allowed?(nil, oid(ctx), @base)
      refute Edition.harness_source_allowed?(cid(ctx.client), nil, @base)
    end

    test "the operator itself, which owns no link as a client", ctx do
      refute allowed?(oid(ctx), cid(ctx.client), @base)
    end
  end

  describe "another operator's source" do
    test "is refused for a client that is not its client", ctx do
      assign!(ctx.elsewhere, ctx.other_client, @base)

      assert allowed?(cid(ctx.other_client), ctx.elsewhere.organisation.id, @base)
      refute allowed?(cid(ctx.client), ctx.elsewhere.organisation.id, @base)
      refute allowed?(cid(ctx.client), oid(ctx), @base)
      refute allowed?(cid(ctx.other_client), oid(ctx), @base)
    end

    test "is refused while a stored row names an owner the tenant does not", ctx do
      # A row of the first operator for a client of the second: the tenant says no.
      Repo.insert!(%Assignment{
        operator_id: oid(ctx),
        organisation_id: cid(ctx.other_client),
        git: @git,
        ref: "main",
        path: "core"
      })

      refute allowed?(cid(ctx.other_client), oid(ctx), @base)
    end
  end

  describe "a document a client's people saved" do
    test "that lists the operator's repository does not make it the client's to use", ctx do
      private = %{"git" => "https://code.example.com/operator/private", "ref" => "main"}
      document = "extends: {git: #{private["git"]}, ref: main}\n"

      assert {:ok, stack} =
               Stacks.put_stack(
                 ctx.client.owner.scope,
                 {:workspace, ctx.client.workspace},
                 document
               )

      # The owner is the client, so the core's first rule gives the client's links.
      assert stack.owner_organisation_id == cid(ctx.client)
      assert allowed?(cid(ctx.client), stack.owner_organisation_id, private)

      # The operator's links are not the client's: nothing assigns the source.
      refute allowed?(cid(ctx.client), oid(ctx), private)
      refute allowed?(cid(ctx.client), oid(ctx), %{private | "ref" => "next"})
    end
  end

  describe "a source that a document of the operator lists" do
    @listed_module %{
      "git" => "https://code.example.com/team/modules",
      "ref" => "v1",
      "module" => "lint"
    }
    @document """
    extends: {git: #{@git}, ref: main, path: core}
    modules:
      - source: {git: https://code.example.com/team/modules, ref: v1, module: lint}
    """

    # The operator saves its document in the client's workspace, with the flag on.
    defp save!(user_scope, place, document) do
      {:ok, stack} = Stacks.put_stack(user_scope, place, document)
      stack
    end

    setup ctx do
      stack = save!(ctx.client.scope, {:workspace, ctx.client.workspace}, @document)
      assert stack.owner_organisation_id == oid(ctx)
      refute Repo.exists?(Assignment)
      :ok
    end

    test "passes as the base of the document, with no assignment", ctx do
      assert allowed?(cid(ctx.client), oid(ctx), @base)
      assert Edition.harness_source_allowed?(cid(ctx.client), oid(ctx), @base)
    end

    test "passes as a module source of the document", ctx do
      assert allowed?(cid(ctx.client), oid(ctx), @listed_module)
    end

    test "is refused at another ref or at another path, as written", ctx do
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "ref" => "next"})
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "path" => "other"})
      refute allowed?(cid(ctx.client), oid(ctx), %{@base | "git" => @git <> "/"})
      refute allowed?(cid(ctx.client), oid(ctx), %{@listed_module | "ref" => "v2"})
      refute allowed?(cid(ctx.client), oid(ctx), @root)
    end

    test "is refused when only a document the client's people saved lists it", ctx do
      private = %{"git" => "https://code.example.com/client/private", "ref" => "main"}

      save!(
        ctx.client.owner.scope,
        {:organisation, ctx.client.organisation},
        "extends: {git: #{private["git"]}, ref: main}\n"
      )

      assert allowed?(cid(ctx.client), cid(ctx.client), private)
      refute allowed?(cid(ctx.client), oid(ctx), private)
    end

    test "is refused for another client of the operator", ctx do
      assert allowed?(cid(ctx.client), oid(ctx), @base)
      refute allowed?(cid(ctx.second), oid(ctx), @base)
      refute allowed?(cid(ctx.second), oid(ctx), @listed_module)
    end

    test "is refused for a client of another operator, whoever the owner", ctx do
      assert allowed?(cid(ctx.client), oid(ctx), @base)
      refute allowed?(cid(ctx.other_client), oid(ctx), @base)
      refute allowed?(cid(ctx.other_client), ctx.elsewhere.organisation.id, @base)
      refute allowed?(cid(ctx.client), ctx.elsewhere.organisation.id, @base)
    end

    test "is refused when the document of another operator lists it", ctx do
      other_id = ctx.elsewhere.organisation.id
      source = %{"git" => @git, "ref" => "other"}

      stack =
        save!(
          ctx.other_client.scope,
          {:workspace, ctx.other_client.workspace},
          "extends: {git: #{@git}, ref: other}\n"
        )

      assert stack.owner_organisation_id == other_id
      assert allowed?(cid(ctx.other_client), other_id, source)

      refute allowed?(cid(ctx.client), oid(ctx), source)
      refute allowed?(cid(ctx.client), other_id, source)
      refute allowed?(cid(ctx.other_client), oid(ctx), source)
    end

    test "is refused while a stored row names an owner the tenant does not", ctx do
      # A document of the first operator in a client of the second: the tenant says no.
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: cid(ctx.other_client),
        workspace_id: ctx.other_client.workspace.id,
        owner_organisation_id: oid(ctx),
        harness: @document
      })

      refute allowed?(cid(ctx.other_client), oid(ctx), @base)
    end

    test "is refused with the flag off", ctx do
      Flags.put_operator_infrastructure(false)

      refute allowed?(cid(ctx.client), oid(ctx), @base)
      refute allowed?(cid(ctx.client), oid(ctx), @listed_module)
      refute Edition.harness_source_allowed?(cid(ctx.client), oid(ctx), @base)
    end
  end

  describe "with the flag off" do
    test "the answer is false, an assignment included", ctx do
      assign!(ctx.operator, ctx.client, @base)
      assert allowed?(cid(ctx.client), oid(ctx), @base)

      Flags.put_operator_infrastructure(false)

      refute allowed?(cid(ctx.client), oid(ctx), @base)
      refute Edition.harness_source_allowed?(cid(ctx.client), oid(ctx), @base)
    end
  end

  describe "the instance's organisation as the owner" do
    test "stays the core's answer: an instance assignment covers a client of an operator",
         ctx do
      instance_id = instance_organisation().id
      client_id = cid(ctx.client)

      # No instance assignment: the core refuses and the edition does not allow the instance's.
      refute allowed?(client_id, instance_id, @base)

      Repo.insert!(%Harnesses.Assignment{
        organisation_id: client_id,
        every_organisation: false,
        source: @base
      })

      assert allowed?(client_id, instance_id, @base)
      refute allowed?(client_id, instance_id, %{@base | "path" => "other"})
      # The instance's assignment is not the operator's.
      refute allowed?(client_id, oid(ctx), @base)
    end
  end

  describe "assign/3" do
    test "refuses a client that is not the operator's", ctx do
      assert HarnessAssignments.assign(oid(ctx), cid(ctx.other_client), @base) ==
               {:error, :not_found}

      assert HarnessAssignments.assign(oid(ctx), oid(ctx), @base) == {:error, :not_found}

      assert HarnessAssignments.assign(oid(ctx), Ecto.UUID.generate(), @base) ==
               {:error, :not_found}

      assert HarnessAssignments.assign(oid(ctx), "client", @base) == {:error, :not_found}
      assert HarnessAssignments.assign(cid(ctx.client), oid(ctx), @base) == {:error, :not_found}
      refute Repo.exists?(Assignment)
    end

    test "refuses a second assignment of the same source, and a source that is none", ctx do
      assert %Assignment{} = assign!(ctx.operator, ctx.client, @base)

      assert {:error, changeset} = HarnessAssignments.assign(oid(ctx), cid(ctx.client), @base)
      assert %{source: [_message]} = errors_on(changeset)

      # Another client, another narrowing key and the root are other sources.
      assert %Assignment{} = assign!(ctx.operator, ctx.second, @base)
      assert %Assignment{} = assign!(ctx.operator, ctx.client, @export)
      assert %Assignment{} = assign!(ctx.operator, ctx.client, @root)

      for source <- [
            Map.put(@base, "stack", "web"),
            %{"git" => @git},
            %{@base | "path" => ""},
            %{@base | "ref" => ""},
            Map.put(@base, "name", "x"),
            %{@base | "path" => 1},
            nil
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 HarnessAssignments.assign(oid(ctx), cid(ctx.client), source),
               inspect(source)
      end

      assert length(HarnessAssignments.list(oid(ctx), cid(ctx.client))) == 3
    end

    test "refuses a second assignment of a root source, which has no path", ctx do
      assert %Assignment{path: nil} = assign!(ctx.operator, ctx.client, @root)

      assert {:error, changeset} = HarnessAssignments.assign(oid(ctx), cid(ctx.client), @root)
      assert %{source: [_message]} = errors_on(changeset)
    end

    test "is refused by the database for two narrowing keys or an empty text", ctx do
      row = %{operator_id: oid(ctx), organisation_id: cid(ctx.client), git: @git, ref: "main"}

      assert_raise Ecto.ConstraintError, ~r/operator_harness_assignments_narrowing/, fn ->
        Repo.insert!(struct!(Assignment, Map.merge(row, %{path: "a", stack: "b"})))
      end

      assert_raise Ecto.ConstraintError, ~r/operator_harness_assignments_not_empty/, fn ->
        Repo.insert!(struct!(Assignment, Map.put(row, :path, "")))
      end
    end
  end

  describe "unassign/3 and list/2" do
    test "list the operator's assignments to one client, and unassign one", ctx do
      assign!(ctx.operator, ctx.client, @base)
      assign!(ctx.operator, ctx.client, @export)
      assign!(ctx.operator, ctx.second, @module)
      assign!(ctx.elsewhere, ctx.other_client, @root)

      sources =
        HarnessAssignments.list(oid(ctx), cid(ctx.client)) |> Enum.map(&Assignment.source/1)

      assert sources == [@base, @export]
      assert HarnessAssignments.list(oid(ctx), cid(ctx.other_client)) == []

      assert {:ok, %Assignment{}} = HarnessAssignments.unassign(oid(ctx), cid(ctx.client), @base)
      assert HarnessAssignments.unassign(oid(ctx), cid(ctx.client), @base) == {:error, :not_found}

      assert HarnessAssignments.unassign(oid(ctx), cid(ctx.client), @module) ==
               {:error, :not_found}

      assert HarnessAssignments.unassign(oid(ctx), cid(ctx.other_client), @root) ==
               {:error, :not_found}

      assert HarnessAssignments.unassign(oid(ctx), cid(ctx.client), nil) == {:error, :not_found}

      assert [@export] ==
               HarnessAssignments.list(oid(ctx), cid(ctx.client))
               |> Enum.map(&Assignment.source/1)
    end
  end
end
