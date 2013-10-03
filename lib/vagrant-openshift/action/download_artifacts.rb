#--
# Copyright 2013 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++
require 'pathname'

module Vagrant
  module Openshift
    module Action
      class DownloadArtifacts
        include CommandHelper

        def initialize(app, env)
          @app = app
          @env = env
        end

        def call(env)
          machine = @env[:machine]
          machine.ui.info "Downloading logs and rpms"

          artifacts_dir = Pathname.new(File.expand_path(machine.env.root_path + "artifacts"))
          download_map = {
            "/tmp/rhc/"                            => artifacts_dir + "test_runs/",
            "/var/log/openshift/"                  => artifacts_dir + "openshift_logs/",
            "/var/log/httpd/"                      => artifacts_dir + "node_httpd_logs/",
            "/var/log/yum.log"                     => artifacts_dir + "yum.log",
            "/var/log/messages"                    => artifacts_dir + "messages",
            "/var/log/secure"                      => artifacts_dir + "secure",
            "/var/log/audit/audit.log"             => artifacts_dir + "audit.log",
            #"/tmp/rhc/*_coverage"                  => artifacts_dir + "coverage/",
            "/var/log/mcollective.*"               => artifacts_dir + "mcollective/",
            "#{Constants.build_dir}/origin-rpms/"  => artifacts_dir + "rpms/",
            "#{Constants.build_dir}/origin-srpms/" => artifacts_dir + "srpms/",
          }

          download_map.each do |k,v|
            machine.ui.info "Downloading artifacts from '#{k}' to '#{v}'"
            if v.to_s.end_with? '/'
              FileUtils.mkdir_p v.to_s
            else
              FileUtils.mkdir_p File.dirname(v.to_s)
            end

            ssh_info = env[:machine].ssh_info
            command = [
                "rsync", "--verbose", "--human-readable", "--compress", "--recursive", "--perms",
                "--times", "--stats", "--delete", "--rsync-path", "sudo rsync",
                "--rsh", "ssh -p #{ssh_info[:port]} -o StrictHostKeyChecking=no -i '#{ssh_info[:private_key_path]}'",
                "#{ssh_info[:username]}@#{ssh_info[:host]}:#{k}", "#{v}"
            ]

            r = Vagrant::Util::Subprocess.execute(*command)
            if r.exit_code != 0
              machine.ui.warn "Unable to download artifact"
              machine.ui.warn r.stderr
            end
          end
          @app.call(env)
        end
      end
    end
  end
end