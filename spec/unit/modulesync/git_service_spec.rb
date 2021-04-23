require 'modulesync/git_service'

describe ModuleSync::GitService do
  before do
    options = ModuleSync.config_defaults.merge({
      git_base: 'file:///tmp/dummy',
    })
    ModuleSync.instance_variable_set '@options', options
  end

  context 'when instantiate a GitHub service without credentials' do
    it 'raises an error' do
      expect { ModuleSync::GitService.instantiate(type: :github, endpoint: nil, token: nil) }.to raise_error(ModuleSync::Error, 'No GitHub token specified to create a pull request')
    end
  end

  context 'when instantiate a GitLab service without credentials' do
    it 'raises an error' do
      expect { ModuleSync::GitService.instantiate(type: :gitlab, endpoint: nil, token: nil) }.to raise_error(ModuleSync::Error, 'No GitLab token specified to create a merge request')
    end
  end

  context 'when guessing the git service configuration' do
    before do
      allow(ENV).to receive(:[])
        .and_return(nil)
    end

    let(:sourcecode) do
      ModuleSync::SourceCode.new 'puppet-test', sourcecode_options
    end

    context 'when using a complete git service configuration entry' do
      let(:sourcecode_options) do
        {
          gitlab: {
            base_url: 'https://vcs.example.com/api/v4',
            token: 'secret',
          },
        }
      end

      it 'build git service arguments from configuration entry' do
        expect(ModuleSync::GitService.configuration_for(sourcecode: sourcecode)).to eq({
          type: :gitlab,
          endpoint: 'https://vcs.example.com/api/v4',
          token: 'secret',
        })
      end
    end

    context 'when using a simple git service key entry' do
      let(:sourcecode_options) do
        {
          gitlab: {},
          remote: 'git@git.example.com:namespace/puppet-test',
        }
      end

      context 'with GITLAB_BASE_URL and GITLAB_TOKEN environment variables sets' do
        it 'build git service arguments from environment variables' do
          allow(ENV).to receive(:[])
            .with('GITLAB_BASE_URL')
            .and_return('https://vcs.example.com/api/v4')
          allow(ENV).to receive(:[])
            .with('GITLAB_TOKEN')
            .and_return('secret')

          expect(ModuleSync::GitService.configuration_for(sourcecode: sourcecode)).to eq({
            type: :gitlab,
            endpoint: 'https://vcs.example.com/api/v4',
            token: 'secret',
          })
        end
      end

      context 'with only GITLAB_TOKEN environment variable sets' do
        it 'guesses the endpoint based on repository remote' do
          allow(ENV).to receive(:[])
            .with('GITLAB_TOKEN')
            .and_return('secret')

          expect(ModuleSync::GitService.configuration_for(sourcecode: sourcecode)).to eq({
            type: :gitlab,
            endpoint: 'https://git.example.com/api/v4',
            token: 'secret',
          })
        end
      end

      context 'without any environment variable sets' do
        it 'raises an error about missing credential' do
          expect{ModuleSync::GitService.configuration_for(sourcecode: sourcecode)}
            .to raise_error ModuleSync::GitService::MissingCredentialsError
        end
      end
    end

    context 'without git service configuration entry' do
      context 'with a guessable endpoint based on repository remote' do
        let(:sourcecode_options) do
          {
            remote: 'git@gitlab.example.com:namespace/puppet-test',
          }
        end

        context 'with a GITLAB_TOKEN environment variable sets' do
          it 'guesses git service configuration' do
            allow(ENV).to receive(:[])
              .with('GITLAB_TOKEN')
              .and_return('secret')

            expect(ModuleSync::GitService.configuration_for(sourcecode: sourcecode)).to eq({
              type: :gitlab,
              endpoint: 'https://gitlab.example.com/api/v4',
              token: 'secret',
            })
          end
        end

        context 'without a GITLAB_TOKEN environment variable sets' do
          it 'raise an error about missing credential' do
            expect{ModuleSync::GitService.configuration_for(sourcecode: sourcecode)}
              .to raise_error ModuleSync::Error
          end
        end
      end

      context 'with a unguessable endpoint' do
        let(:sourcecode_options) do
          {
            remote: 'git@vcs.example.com:namespace/puppet-test',
          }
        end

        context 'with GITHUB_TOKEN environments variable sets' do
          it 'guesses git service configuration' do
            allow(ENV).to receive(:[])
              .with('GITHUB_TOKEN')
              .and_return('secret')

            expect(ModuleSync::GitService.configuration_for(sourcecode: sourcecode)).to eq({
              type: :github,
              endpoint: 'https://vcs.example.com',
              token: 'secret',
            })
          end
        end

        context 'with GITLAB_TOKEN and GITHUB_TOKEN environments variables sets' do
          it 'raises an error' do
            allow(ENV).to receive(:[])
              .with('GITHUB_TOKEN')
              .and_return('secret')

            allow(ENV).to receive(:[])
              .with('GITLAB_TOKEN')
              .and_return('secret')

            expect{ModuleSync::GitService.configuration_for(sourcecode: sourcecode)}
              .to raise_error ModuleSync::Error
          end
        end
      end
    end
  end
end
