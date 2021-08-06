defmodule Membrane.WAV.PostprocessingTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  alias Membrane.File.{Source, Sink}
  alias Membrane.Testing.Pipeline
  alias Membrane.WAV.{Parser, Postprocessing, Serializer}

  @input_path Path.expand("../fixtures/input.wav", __DIR__)
  @reference_path Path.expand("../fixtures/reference_processed.wav", __DIR__)
  @output_path Path.expand("../fixtures/output.wav", __DIR__)

  test "correct_wav_header/1 should perform proper postprocessing" do
    on_exit(fn -> File.rm(@output_path) end)

    elements = [
      file_src: %Source{location: @input_path},
      parser: Parser,
      serializer: Serializer,
      file_sink: %Sink{location: @output_path}
    ]

    links = [
      link(:file_src)
      |> to(:parser)
      |> to(:serializer)
      |> to(:file_sink)
    ]

    pipeline_options = %Pipeline.Options{elements: elements, links: links}
    assert {:ok, pid} = Pipeline.start_link(pipeline_options)
    assert Pipeline.play(pid) == :ok
    assert_end_of_stream(pid, :file_sink, :input, 2_000)
    Pipeline.stop_and_terminate(pid, blocking?: true)

    assert :ok = Postprocessing.correct_wav_header(@output_path)

    {:ok, processed} = File.read(@output_path)
    {:ok, reference} = File.read(@reference_path)

    assert processed == reference
  end
end
