#
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

module Vagrant
  module Openshift
    module Action
      class PushOpenshiftImages
        include CommandHelper

        def initialize(app, env, options)
          @app = app
          @env = env
          @options = options
        end

        # FIXME: This is a temporary fix as the RHEL7 AMI should have this
        #        registry here already.
        def fix_insecure_registry_cmd(registry_url)
          %{
sudo cat <<EOF > /etc/sysconfig/docker
OPTIONS='--insecure-registry #{registry_url} --selinux-enabled'
EOF
sudo systemctl restart docker
          }
        end

        def push_image(image_name, git_ref, registry)
          %{
set -e
pushd /tmp/images/#{image_name}
git checkout #{git_ref}
git_ref=$(git rev-parse --short HEAD)
echo "Pushing image #{image_name}:$git_ref..."

docker tag -f #{image_name}-centos7 #{registry}#{image_name}-centos7:$git_ref
docker tag -f #{image_name}-centos7 #{registry}#{image_name}-centos7:latest
docker tag -f #{image_name}-centos7 docker.io/#{image_name}-centos7:latest
docker tag -f #{image_name}-rhel7 #{registry}#{image_name}-rhel7:$git_ref
docker tag -f #{image_name}-rhel7 #{registry}#{image_name}-rhel7:latest

#docker push -f #{registry}#{image_name}-centos7:$git_ref
#docker push -f docker.io/#{image_name}-centos7:latest
#docker push -f #{registry}#{image_name}-rhel7:$git_ref
#docker push -f #{registry}#{image_name}-centos7:latest
#docker push -f #{registry}#{image_name}-rhel7:latest

# We can't fully parallelize this because docker fails when you push to the same repo at the
# same time (using different tags), so we do two groups of push operations.
procs[0]="docker push -f #{registry}#{image_name}-centos7:$git_ref"
procs[1]="docker push -f docker.io/#{image_name}-centos7:latest"
procs[2]="docker push -f #{registry}#{image_name}-rhel7:$git_ref"

# Run pushes in parallel
for i in {0..2}; do
  echo "pushing ${procs[${i}]}" 
  ${procs[${i}]} & 
  pids[${i}]=$!
  echo "push ${procs[${i}]} is pid ${pids[${i}]}" 
done 

# Wait for all pushes.  "wait" will check the return code of each process also.
for pid in ${pids[*]}; do
  echo "checking $pid" 
  wait $pid 
done

procs[0]="docker push -f #{registry}#{image_name}-centos7:latest"
procs[1]="docker push -f #{registry}#{image_name}-rhel7:latest"

# Run pushes in parallel
for i in {0..1}; do 
  ${procs[${i}]} & 
  pids[${i}]=$!
done 

# Wait for all pushes.  "wait" will check the return code of each process also.
for pid in ${pids[*]}; do
  wait $pid 
done

popd
set +e
          }
        end

# Note that this only invokes "make test" on the image, if the tests
# succeed the candidate produced by "make test" will be pushed.  There
# is an implicit assumption here that the image produced by make test
# is identical to what would be produced by a subsequent "make build" 
# call, so there's no point in explicitly calling "make build" after
# "make test"
        def build_image(image_name, version, git_ref, repo_url)
          %{
dest_dir=/tmp/images/#{image_name}
rm -rf ${dest_dir}; mkdir -p ${dest_dir}
set -e
pushd ${dest_dir}
git init && git remote add -t master origin #{repo_url}
git fetch && git checkout #{git_ref}
git_ref=$(git rev-parse --short HEAD)
echo "Building and testing #{image_name}-centos7:$git_ref ..."
sudo make test TARGET=centos7 VERSION=#{version} TAG_ON_SUCCESS=true
echo "Building and testing #{image_name}-rhel7:$git_ref ..."
sudo make test TARGET=rhel7 VERSION=#{version} TAG_ON_SUCCESS=true
popd
set +e
          }
        end

        def update_latest_image_cmd(registry)
          cmd = %{
rm -rf ~/latest_images ; touch ~/latest_images
          }
          Vagrant::Openshift::Constants.openshift_images.each do |name, git_url|
            cmd += %{
set +e
git_ref=$(git ls-remote #{git_url} -h refs/heads/master | cut -c1-7)
curl -s http://#{registry}v1/repositories/#{name}-rhel7/tags/${git_ref} | grep -q "error"
if [[ "$?" != "0" ]]; then
  echo "#{name};$git_ref" >> ~/latest_images
fi
            }
          end
          return cmd
        end

        def call(env)
          cmd = fix_insecure_registry_cmd(@options[:registry])
          if !@options[:registry].end_with?('/')
            @options[:registry] += "/"
          end

          cmd += %{
set -x
set +e
echo "Pre-pulling base images ..."
docker pull #{@options[:registry]}openshift/base-centos7
[[ "$?" == "0" ]] && docker tag -f #{@options[:registry]}openshift/base-centos7 openshift/base-centos7
docker pull #{@options[:registry]}openshift/base-rhel7
[[ "$?" == "0" ]] && docker tag -f #{@options[:registry]}openshift/base-rhel7 openshift/base-rhel7
          }

          cmd += %{
# so we can call sti
PATH=/data/src/github.com/openshift/source-to-image/_output/go/bin:/data/src/github.com/openshift/source-to-image/_output/local/go/bin:$PATH
          }

          # FIXME: We always need to make sure we have the latest base image
          # FIXME: This is because the internal registry is pruned once per month
          if !@options[:build_images].include?("openshift/base")
            @options[:build_images] = "openshift/base:1:master,#{@options[:build_images]}"
          end

          build_images = @options[:build_images].split(",").map { |i| i.strip }

          push_cmd = ""
          build_images.each do |image|
            name, version, git_ref = image.split(':')
            repo_url = Vagrant::Openshift::Constants.openshift_images[name]
            if repo_url == nil
              puts "Unregistered image: #{name}, skipping"
              next
            end
            cmd += build_image(name, version, git_ref, repo_url)
            push_cmd += push_image(name, git_ref, @options[:registry])
          end

          # Push the final images **only** when they all build successfully
          cmd += push_cmd
          cmd += update_latest_image_cmd(@options[:registry])

          do_execute(env[:machine], cmd)

          @app.call(env)
        end
      end
    end
  end
end
