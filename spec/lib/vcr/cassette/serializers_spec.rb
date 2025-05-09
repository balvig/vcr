require 'support/ruby_interpreter'
require 'vcr/cassette/serializers'
require 'json'

begin
  require 'psych' # ensure psych is loaded for these tests if its available
rescue LoadError
end

module VCR
  class Cassette
    ::RSpec.describe Serializers do
      shared_examples_for "encoding error handling" do |name, error_class|
        context "the #{name} serializer" do
          it 'appends info about the :preserve_exact_body_bytes option to the error' do
            expect {
              result = serializer.serialize("a" => string)
              serializer.deserialize(result)
            }.to raise_error(error_class, /preserve_exact_body_bytes/)
          end
        end
      end

      shared_examples_for "syntax error handling" do |name, error_class|
        context "the #{name} serializer" do
          it 'appends info about the :erb option to the error' do
            expect {
              begin
                serialized
              rescue => e
                e.message << "\n#{serializer.serialize("a" => "bc").inspect}"
                raise
              end
              serializer.deserialize(serialized)
            }.to raise_error(error_class, /erb/)
          end
        end
      end

      shared_examples_for "a serializer" do |name, file_extension, lazily_loaded|
        let(:serializer) { subject[name] }

        context "the #{name} serializer" do
          it 'lazily loads the serializer' do
            serializers = subject.instance_variable_get(:@serializers)
            expect(serializers).not_to have_key(name)
            expect(subject[name]).not_to be_nil
            expect(serializers).to have_key(name)
          end if lazily_loaded

          it "returns '#{file_extension}' as the file extension" do
            expect(serializer.file_extension).to eq(file_extension)
          end

          it "can serialize and deserialize a hash" do
            hash = { "a" => 7, "null value" => nil, "nested" => { "hash" => [1, 2, 3] }}
            serialized = serializer.serialize(hash)
            expect(serialized).not_to eq(hash)
            expect(serialized).to be_a(String)
            deserialized = serializer.deserialize(serialized)
            expect(deserialized).to eq(hash)
          end
        end
      end

      it_behaves_like "a serializer", :yaml,  "yml",  :lazily_loaded do
        it_behaves_like "encoding error handling", :yaml, ArgumentError do
          let(:string) { "\xFA".force_encoding("UTF-8") }
          before { ::YAML::ENGINE.yamler = 'psych' if defined?(::YAML::ENGINE) }
        end

        it_behaves_like "syntax error handling", :yaml, ::Psych::SyntaxError do
          let(:serialized) { <<~YAML }
            ---
            a: <%=
              'bc'.to_json
            %>
          YAML
          before { ::YAML::ENGINE.yamler = 'psych' if defined?(::YAML::ENGINE) }
        end
      end

      it_behaves_like "a serializer", :syck,  "yml",  :lazily_loaded do
        it_behaves_like "encoding error handling", :syck, ArgumentError do
          let(:string) { "\xFA".force_encoding("UTF-8") }
        end

        it_behaves_like "syntax error handling", :syck, ::Psych::SyntaxError do
          let(:serialized) { <<~YAML }
            ---
            a: <%=
              'bc'.to_json
            %>
          YAML
        end
      end

      it_behaves_like "a serializer", :psych, "yml",  :lazily_loaded do
        it_behaves_like "encoding error handling", :psych, ArgumentError do
          let(:string) { "\xFA".force_encoding("UTF-8") }
        end

        it_behaves_like "syntax error handling", :psych, ::Psych::SyntaxError do
          let(:serialized) { <<~YAML }
            ---
            a: <%=
              'bc'.to_json
            %>
          YAML
        end
      end if defined?(::Psych)

      it_behaves_like "a serializer", :compressed, "zz",  :lazily_loaded do
        it_behaves_like "encoding error handling", :compressed, ArgumentError do
          let(:string) { "\xFA".force_encoding("UTF-8") }
        end

        it_behaves_like "syntax error handling", :compressed, ::Psych::SyntaxError do
          let(:serialized) { Zlib::Deflate.deflate(<<~YAML) }
            ---
            a: <%=
              'bc'.to_json
            %>
          YAML
        end
      end

      it_behaves_like "a serializer", :json,  "json", :lazily_loaded do
        it_behaves_like "encoding error handling", :json, ::JSON::GeneratorError do
          let(:string) { "\xFA" }
        end

        it_behaves_like "syntax error handling", :json, ::JSON::ParserError do
          let(:serialized) { <<~JSON }
            {
              "a": <%=
                'bc'.to_json
              %>
            }
          JSON
        end
      end

      context "a custom :ruby serializer" do
        let(:custom_serializer) do
          Object.new.tap do |obj|
            def obj.file_extension
              "rb"
            end

            def obj.serialize(hash)
              hash.inspect
            end

            def obj.deserialize(string)
              eval(string)
            end
          end
        end

        before(:each) do
          subject[:ruby] = custom_serializer
        end

        it_behaves_like "a serializer", :ruby, "rb", false
      end

      describe "#[]=" do
        context 'when there is already a serializer registered for the given name' do
          before(:each) do
            subject[:foo] = :old_serializer
            allow(subject).to receive :warn
          end

          it 'overrides the existing serializer' do
            subject[:foo] = :new_serializer
            expect(subject[:foo]).to be(:new_serializer)
          end

          it 'warns that there is a name collision' do
            expect(subject).to receive(:warn).with(
              /WARNING: There is already a VCR cassette serializer registered for :foo\. Overriding it/
            )
            subject[:foo] = :new_serializer
          end
        end
      end

      describe "#[]" do
        it 'raises an error when given an unrecognized serializer name' do
          expect { subject[:foo] }.to raise_error(ArgumentError)
        end

        it 'returns the named serializer' do
          expect(subject[:yaml]).to be(VCR::Cassette::Serializers::YAML)
        end
      end

      # see https://gist.github.com/815769
      problematic_syck_string = "1\n \n2"

      describe "psych serializer" do
        it 'serializes things using pysch even if syck is configured as the default YAML engine' do
          ::YAML::ENGINE.yamler = 'syck'
          serialized = subject[:psych].serialize(problematic_syck_string)
          expect(subject[:psych].deserialize(serialized)).to eq(problematic_syck_string)
        end if defined?(::Psych) && defined?(::YAML::ENGINE)

        it 'raises an error if psych cannot be loaded' do
          expect { subject[:psych] }.to raise_error(LoadError)
        end unless defined?(::Psych)
      end
    end
  end
end
