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

    test "under a policy that names an image is no top-level image, and for a prebuild the policy without it" do
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

    test "whose image is fixed, under a policy that names one since, keeps it beside the policy without the policy's" do
      without = ComposedConfiguration.without_image(@naming)

      assert ComposedConfiguration.shape(@naming, @image, false, true) ==
               {:composed, ComposedConfiguration.compose(without, @image), @image}

      assert ComposedConfiguration.digest(@naming, @image, false, true) ==
               Render.digest(ComposedConfiguration.compose(without, @image))

      # A run that was given no image is given the policy as it is; a prebuild the
      # policy without its image, as before.
      assert ComposedConfiguration.shape(@naming, nil, false, true) == :as_is

      assert ComposedConfiguration.shape(@naming, nil, true, true) ==
               {:composed, without, nil}

      # A policy that names no image is composed as at the attach.
      assert ComposedConfiguration.shape(@document, @image, false, true) ==
               ComposedConfiguration.shape(@document, @image, false)
    end

    test "that started in its policy's image keeps it in the policy, the document as it is when the same" do
      renaming = String.replace(@naming, ~s("with-docker"), ~s("with-gpu"))

      assert ComposedConfiguration.shape(renaming, {:policy, "with-docker"}, false, true) ==
               {:composed, @naming, nil}

      assert ComposedConfiguration.shape(@naming, {:policy, "with-docker"}, false, true) ==
               :as_is

      # A policy that names none is given the start's image after its other members.
      assert ComposedConfiguration.shape(@document, {:policy, "with-docker"}, false, true) ==
               {:composed,
                ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":["api.example"]},"image":"with-docker"}}),
                nil}

      # Never composed from no policy, nor before the attach, nor for a prebuild.
      assert ComposedConfiguration.shape(nil, {:policy, "with-docker"}, false, true) == :as_is

      assert ComposedConfiguration.shape(renaming, {:policy, "with-docker"}, true, true) ==
               {:composed, ComposedConfiguration.without_image(renaming), nil}
    end

    test "that started in no image is given the policy without the image it comes to name" do
      assert ComposedConfiguration.shape(@naming, :none, false, true) ==
               {:composed, ComposedConfiguration.without_image(@naming), nil}

      assert ComposedConfiguration.shape(@document, :none, false, true) == :as_is
      assert ComposedConfiguration.shape(nil, :none, false, true) == :as_is
    end

    test "is read from what the run started in" do
      run = %Apiary.Runs.Run{}
      assert ComposedConfiguration.started(nil) == nil
      assert ComposedConfiguration.started(run) == nil
      assert ComposedConfiguration.started(%{run | configured_image: @image}) == @image

      assert ComposedConfiguration.started(%{
               run
               | started_image_from: "top_level",
                 started_image: @image,
                 configured_image: @image
             }) == @image

      assert ComposedConfiguration.started(%{
               run
               | started_image_from: "policy",
                 started_image: "with-docker"
             }) == {:policy, "with-docker"}

      assert ComposedConfiguration.started(%{run | started_image_from: "none"}) == :none

      assert ComposedConfiguration.policy_image(@naming) == "with-docker"
      assert ComposedConfiguration.policy_image(@document) == nil
      assert ComposedConfiguration.policy_image(nil) == nil
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

      # The same bytes in the other workspace are another row, of that workspace.
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

  # P2: `p1` with an image added to its security_policy, nothing else changed: leaving the
  # image out of P2 gives P1's bytes.
  defp image_only!(scope, p1) do
    %Jason.OrderedObject{values: members} =
      Jason.decode!(p1.document, objects: :ordered_objects)

    members =
      Enum.map(members, fn
        {"security_policy", %Jason.OrderedObject{values: values}} ->
          {"security_policy", Jason.OrderedObject.new(values ++ [{"image", "with-docker"}])}

        member ->
          member
      end)

    stored!(scope, Jason.encode!(Jason.OrderedObject.new(members), escape: :json))
  end

  describe "a policy that comes to name an image and nothing else" do
    test "reloads a run given an image under a row of the new version, behind nothing", ctx do
      p1 = ctx.configuration
      {:ok, attached} = serve(ctx.scope, p1, @image)

      p2 = image_only!(ctx.scope, p1)
      assert ComposedConfiguration.without_image(p2.document) == p1.document

      {:ok, reloaded} =
        ComposedConfiguration.serve(
          ctx.scope.organisation.id,
          ctx.scope.workspace.id,
          p2,
          @image,
          false,
          true
        )

      # The same bytes, kept twice: each row names the version it was composed from.
      assert reloaded.digest == attached.digest
      refute reloaded.id == attached.id
      assert reloaded.run_configuration_id == p2.id
      assert Repo.reload!(attached).run_configuration_id == p1.id

      run =
        run_fixture(ctx.scope, %{
          configured_image: @image,
          reported_run_configuration_digest: reloaded.digest,
          run_configuration_digest: reloaded.digest
        })

      assert Policy.digests(ctx.scope, run) == %{
               in_force: p2.digest,
               reported: p2.digest,
               applied: p2.digest,
               drift: false
             }

      assert Policy.answered_digest(ctx.scope, run) == reloaded.digest
      assert %{n: 2} = Rules.version(ctx.scope, nil, reloaded.digest)
    end

    test "never takes a stored version's digest for a prebuild's document of the same bytes",
         ctx do
      p1 = ctx.configuration
      p2 = image_only!(ctx.scope, p1)

      # A prebuild under P2 is given P2 without its image: P1's bytes, kept as composed
      # from P2.
      {:ok, prebuild} = serve(ctx.scope, p2, nil, true)
      assert prebuild.digest == p1.digest
      assert prebuild.run_configuration_id == p2.id

      # A run a node registered itself, still on P1, is behind P2.
      run =
        run_fixture(ctx.scope, %{
          reported_run_configuration_digest: p1.digest,
          run_configuration_digest: p1.digest
        })

      assert %{in_force: in_force, reported: reported, applied: applied, drift: true} =
               Policy.digests(ctx.scope, run)

      assert in_force == p2.digest
      assert reported == p1.digest
      assert applied == p1.digest
      assert Policy.policy_digest(ctx.scope, p1.digest) == p1.digest
      assert %{n: 1} = Rules.version(ctx.scope, nil, p1.digest)

      # A run the events endpoint does not know, reporting P1, is not told P1 is in force.
      %{access_key: key} = contract_key_fixture(ctx.scope)
      batch = %Batch{subject: Ecto.UUID.generate(), events: []}
      assert Serving.digest_for(key, nil, batch, p1.digest) == p2.digest
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
          configured_image: @image,
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

    test "of a run that started in its policy's image is no drift while its policy is in force",
         ctx do
      renaming = stored!(ctx.scope, String.replace(@naming, ~s("with-docker"), ~s("with-gpu")))

      {:ok, composed} =
        ComposedConfiguration.serve(
          ctx.scope.organisation.id,
          ctx.scope.workspace.id,
          renaming,
          {:policy, "with-docker"},
          false,
          true
        )

      assert composed.document == @naming
      assert composed.run_configuration_id == renaming.id

      run =
        run_fixture(ctx.scope, %{
          started_image_from: "policy",
          started_image: "with-docker",
          reported_run_configuration_digest: composed.digest,
          run_configuration_digest: composed.digest
        })

      assert ComposedConfiguration.run_digest(renaming, run) == composed.digest

      assert Policy.digests(ctx.scope, run) == %{
               in_force: renaming.digest,
               reported: renaming.digest,
               applied: renaming.digest,
               drift: false
             }

      assert %{digest: digest} = Rules.version(ctx.scope, nil, composed.digest)
      assert digest == renaming.digest
    end

    test "is in force for the events endpoint only for a run it would be answered to", ctx do
      {:ok, composed} = serve(ctx.scope, ctx.configuration, @image)
      %{access_key: key} = contract_key_fixture(ctx.scope)
      batch = %Batch{subject: Ecto.UUID.generate(), events: []}

      # A run given the image whose target is not known yet is answered the digest it
      # reported, while that is what its reload would give.
      run = run_fixture(ctx.scope, %{configured_image: @image})
      assert Serving.digest_for(key, run, batch, composed.digest) == composed.digest

      # A run the endpoint does not know is given no image: the composed digest is no
      # answer of its, and it is told the baseline's.
      assert Serving.digest_for(key, nil, batch, composed.digest) == ctx.configuration.digest

      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "cdn.example"})
      {:ok, newer} = Policy.current_configuration(ctx.scope, nil)

      assert Serving.digest_for(key, run, batch, composed.digest) ==
               ComposedConfiguration.digest(newer.document, @image, false)
    end
  end
end
