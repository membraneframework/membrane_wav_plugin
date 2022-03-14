defmodule Membrane.WAV.SerializerBinTest do
  use ExUnit.Case
  use Membrane.Pipeline

  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline

  @module Membrane.WAV.SerializerBin

  @input_path Path.expand("../fixtures/input.wav", __DIR__)
  @reference_path Path.expand("../fixtures/reference_processed.wav", __DIR__)

  setup_all do
    output_path = Path.join([System.tmp_dir!(), "output.wav"])
    on_exit(fn -> File.rm!(output_path) end)

    [output_path: output_path]
  end

  describe "SerializerBin should" do
    test "serialize and save audio to a file", %{output_path: output_path} do
      elements = [
        file_source: %Membrane.File.Source{location: @input_path},
        parser: Membrane.WAV.Parser,
        serializer_bin: %@module{location: output_path}
      ]

      links = [link(:file_source) |> to(:parser) |> to(:serializer_bin)]

      options = %Pipeline.Options{elements: elements, links: links}

      {:ok, pid} = Pipeline.start_link(options)
      :ok = Pipeline.play(pid)

      assert_pipeline_notified(pid, :serializer_bin, :end_of_stream)
      assert :ok == Pipeline.stop_and_terminate(pid, blocking?: true)

      {:ok, output} = File.read(output_path)
      {:ok, reference} = File.read(@reference_path)

      assert output == reference
    end
  end
end
