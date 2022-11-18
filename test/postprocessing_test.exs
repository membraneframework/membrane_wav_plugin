defmodule Membrane.WAV.PostprocessingTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.File.{Sink, Source}
  alias Membrane.Testing.Pipeline
  alias Membrane.WAV.{Parser, Postprocessing, Serializer}

  @input_path Path.expand("fixtures/input.wav", __DIR__)
  @reference_path Path.expand("fixtures/reference_processed.wav", __DIR__)

  @invalid_header Path.expand("fixtures/invalid_header.wav", __DIR__)

  describe "fix_wav_header/1 should" do
    @tag :tmp_dir
    test "perform proper postprocessing", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "output.wav")

      structure = [
        child(:file_src, %Source{location: @input_path})
        |> child(:parser, Parser)
        |> child(:serializer, Serializer)
        |> child(:file_sink, %Sink{location: output_path})
      ]

      assert {:ok, _supervisor_pid, pid} = Pipeline.start_link(structure: structure)
      assert_end_of_stream(pid, :file_sink, :input, 2_000)
      Pipeline.terminate(pid, blocking?: true)

      assert :ok = Postprocessing.fix_wav_header(output_path)

      {:ok, processed} = File.read(output_path)
      {:ok, reference} = File.read(@reference_path)

      assert processed == reference
    end

    test "return error in case of invalid header" do
      assert {:error, :invalid_file} = Postprocessing.fix_wav_header(@invalid_header)
    end
  end
end
