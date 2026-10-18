defmodule Apiary.Policy.ComposedConfigurationTest do
  # The run configurations composed for a run: the bytes, what each kind of run is given,
  # the rows kept and read by digest, and the badges and lookups that read a composed
  # digest as the configuration it was composed from.
  use Apiary.DataCase, async: true

  @moduletag needs: :security

  import Apiary.ContractFixtures, only: [contract_key_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 2]

  alias Apiary.Policy
  alias Apiary.Policy.{ComposedConfiguration, Render, RunConfiguration, Schema, Serving}
  alias Apiary.Runs.Batch
  alias ApiaryWeb.ConnectionLive.Rules

  @image "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @other "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("7e0a", 16)
  @policy ~s({"version":1,"egress":{"mode":"enforce","allow":["api.example"]}})
  @document ~s({"version":1,"security_policy":#{@policy}})
  @naming ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["api.example"]},"image":"with-docker"}})

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
    {:ok, configuration} = Policy.current_configuration(scope, nil)
    %{scope: scope, configuration: configuration}
  end

  # A version of the baseline written as it is, past the policy's rendering: what a policy
  # that names an image is stored as.
  defp stored!(scope, document) do
    {:ok, current} = Policy.current_configuration(scope, nil)

    Repo.insert!(%RunConfiguration{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      version: current.version + 1,
      document: document,
      digest: Render.digest(document),
      rendered_at: DateTime.utc_now()
    })
  end

  defp serve(scope, configuration, image, prebuild? \\ false),
    do:
      ComposedConfiguration.serve(
        scope.organisation.id,
        scope.workspace.id,
        configuration,
        image,
        prebuild?
      )

  describe "the bytes" do
    test "put the image beside the security_policy, which stays as it was, byte for byte" do
      composed = ComposedConfiguration.compose(@document, @image)

      assert composed ==
               ~s({"version":1,"image":"#{@image}","security_policy":#{@policy}})

      assert Schema.validate(composed) == :ok
      refute Map.has_key?(Jason.decode!(composed)["security_policy"], "image")
    end

    test "with no document are the version and the image alone" do
      assert ComposedConfiguration.compose(nil, @image) ==
               ~s({"version":1,"image":"#{@image}"})

      assert Schema.validate(ComposedConfiguration.compose(nil, @image)) == :ok
    end

    test "of a prebuild leave out the policy's image and nothing else" do
      assert ComposedConfiguration.without_image(@naming) ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["api.example"]}}})

      assert ComposedConfiguration.names_image?(@naming)
      refute ComposedConfiguration.names_image?(@document)
      refute ComposedConfiguration.names_image?(ComposedConfiguration.compose(@document, @image))
    end

    test "are the same for the same document and image, so is their digest" do
      assert ComposedConfiguration.compose(@document, @image) ==
               ComposedConfiguration.compose(@document, @image)

      assert ComposedConfiguration.digest(@document, @image, false) ==
               Render.digest(ComposedConfiguration.compose(@document, @image))

      refute ComposedConfiguration.digest(@document, @image, false) ==
               ComposedConfiguration.digest(@document, @other, false)
    end
  end

  describe "what a run is given" do
    test "is the document as it is without an image, and composed with one" do
      assert ComposedConfiguration.shape(@document, nil, false) == :as_is
      assert ComposedConfiguration.shape(@document, nil, true) == :as_is
      assert ComposedConfiguration.shape(nil, nil, false) == :as_is
      assert ComposedConfiguration.digest(@document, nil, false) == nil

      assert ComposedConfiguration.shape(@document, @image, false) ==
               {:composed, ComposedConfiguration.compose(@document, @image), @image}

      assert ComposedConfiguration.shape(nil, @image, false) ==
               {:composed, ComposedConfiguration.compose(nil, @image), @image}
    end

    test "under a policy that names an image is no top-level image (V-798), and for a prebuild the policy without it (V-796)" do
      # The image a prebuilt recorded is never asked for: the policy's wins.
      never = fn -> flunk("the image was read") end
      assert ComposedConfiguration.shape(@naming, never, false) == :as_is
      assert ComposedConfiguration.shape(@naming, nil, false) == :as_is

      assert ComposedConfiguration.shape(@naming, nil, true) ==
               {:composed, ComposedConfiguration.without_image(@naming), nil}

      # A prebuild of a policy that names none is asked nothing, and given it as it is.
      assert ComposedConfiguration.shape(@document, nil, fn -> flunk("asked") end) == :as_is

      for {document, image, prebuild?, fixed?} <- [
            {@naming, @image, false, false},
            {@naming, nil, true, false},
            {@naming, @image, false, true}
          ],
          {:composed, bytes, _image} <- [
            ComposedConfiguration.shape(document, image, prebuild?, fixed?)
          ] do
        decoded = Jason.decode!(bytes)

        refute Map.has_key?(decoded, "image") and
                 Map.has_key?(decoded["security_policy"], "image")
      end
    end

    test "whose image is fixed, under a policy that names one since, keeps it beside the policy without the policy's (V-837)" do
      without = ComposedConfiguration.without_image(@naming)

      assert ComposedConfiguration.shape(@naming, @image, false, true) ==
               {:composed, ComposedConfiguration.compose(without, @image), @image}

      assert ComposedConfiguration.digest(@naming, @image, false, true) ==
               Render.digest(ComposedConfiguration.compose(without, @image))

      # A run with no image of its own is given the policy as it is; a prebuild the
      # policy without its image, as before.
      assert ComposedConfiguration.shape(@naming, nil, false, true) == :as_is

      assert ComposedConfiguration.shape(@naming, nil, true, true) ==
               {:composed, without, nil}

      # A policy that names no image is composed as at the attach.
      assert ComposedConfiguration.shape(@document, @image, false, true) ==
               ComposedConfiguration.shape(@document, @image, false)
    end
  end

  describe "the rows" do
    test "are one per document of a workspace, written once and read after", ctx do
      assert serve(ctx.scope, ctx.configuration, nil) == :as_is

      assert {:ok, %ComposedConfiguration{} = first} =
               serve(ctx.scope, ctx.configuration, @image)

      assert first.document == ComposedConfiguration.compose(ctx.configuration.document, @image)
      assert first.digest == Render.digest(first.document)
      assert first.run_configuration_id == ctx.configuration.id
      assert first.image == @image

      assert {:ok, again} = serve(ctx.scope, ctx.configuration, fn -> @image end)
      assert again.id == first.id

      assert {:ok, other} = serve(ctx.scope, ctx.configuration, @other)
      refute other.id == first.id

      assert {:ok, none} = serve(ctx.scope, nil, @image)
      assert none.run_configuration_id == nil
      assert none.document == ~s({"version":1,"image":"#{@image}"})

      assert Repo.aggregate(
               from(c in ComposedConfiguration, where: c.workspace_id == ^ctx.scope.workspace.id),
               :count
             ) == 3

      assert ComposedConfiguration.fetch(ctx.scope.workspace.id, first.digest).id == first.id
    end

    test "of a prebuild under a policy that names an image keep no image", ctx do
      naming = stored!(ctx.scope, @naming)

      assert {:ok, row} = serve(ctx.scope, naming, nil, true)
      assert row.image == nil
      assert row.run_configuration_id == naming.id
      assert row.document == ComposedConfiguration.without_image(@naming)
    end

    test "of another organisation are not reachable", ctx do
      {:ok, mine} = serve(ctx.scope, nil, @image)

      %{scope: other} = sign_up_fixture()
      assert ComposedConfiguration.fetch(other.workspace.id, mine.digest) == nil
      assert ComposedConfiguration.policy_digests(other.workspace.id, [mine.digest]) == %{}

      # The same bytes in the other workspace are a row of its own.
      {:ok, theirs} = serve(other, nil, @image)
      assert theirs.digest == mine.digest
      refute theirs.id == mine.id
      assert theirs.workspace_id == other.workspace.id
    end

    test "go with their run configuration", ctx do
      naming = stored!(ctx.scope, @naming)
      {:ok, row} = serve(ctx.scope, naming, nil, true)

      Repo.delete!(naming)
      assert ComposedConfiguration.fetch(ctx.scope.workspace.id, row.digest) == nil
    end
  end

  describe "a composed digest" do
    test "maps back to the configuration it was composed from, or to no policy", ctx do
      {:ok, composed} = serve(ctx.scope, ctx.configuration, @image)
      {:ok, none} = serve(ctx.scope, nil, @image)
      unknown = "sha256=" <> String.duplicate("0", 64)
      no_policy = Render.digest(Render.no_policy_document())

      assert ComposedConfiguration.policy_digests(ctx.scope.workspace.id, [
               composed.digest,
               none.digest,
               unknown,
               nil
             ]) == %{composed.digest => ctx.configuration.digest, none.digest => no_policy}

      assert Policy.policy_digest(ctx.scope, composed.digest) == ctx.configuration.digest
      assert Policy.policy_digest(ctx.scope, unknown) == unknown
      assert Policy.policy_digest(ctx.scope, nil) == nil
    end

    test "is no drift while its policy is in force, and drift once the policy changes", ctx do
      {:ok, composed} = serve(ctx.scope, ctx.configuration, @image)

      run =
        run_fixture(ctx.scope, %{
          reported_run_configuration_digest: composed.digest,
          run_configuration_digest: composed.digest
        })

      assert Policy.digests(ctx.scope, run) == %{
               in_force: ctx.configuration.digest,
               reported: ctx.configuration.digest,
               applied: ctx.configuration.digest,
               drift: false
             }

      assert %{n: 1, digest: digest} = Rules.version(ctx.scope, nil, composed.digest)
      assert digest == ctx.configuration.digest

      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "cdn.example"})
      {:ok, newer} = Policy.current_configuration(ctx.scope, nil)

      assert %{in_force: in_force, reported: reported, drift: true} =
               Policy.digests(ctx.scope, run)

      assert in_force == newer.digest
      assert reported == ctx.configuration.digest
    end

    test "is in force for the events endpoint while its policy is", ctx do
      {:ok, composed} = serve(ctx.scope, ctx.configuration, @image)
      %{access_key: key} = contract_key_fixture(ctx.scope)

      # A run the endpoint does not know yet is answered the digest it reported, when that
      # is in force.
      batch = %Batch{subject: Ecto.UUID.generate(), events: []}
      assert Serving.digest_for(key, nil, batch, composed.digest) == composed.digest

      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "cdn.example"})
      {:ok, newer} = Policy.current_configuration(ctx.scope, nil)
      assert Serving.digest_for(key, nil, batch, composed.digest) == newer.digest
    end
  end
end
