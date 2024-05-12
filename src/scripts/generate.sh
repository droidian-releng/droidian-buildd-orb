#!/bin/bash

AVAILABLE_ARCHITECTURES="amd64 arm64 armhf"

DEFAULT_SUITE="next"

# Determine branch. On tag builds, CIRCLE_BRANCH is not set, so we infer
# the branch by looking at the actual tag
if [ -n "${CIRCLE_TAG}" ]; then
    REAL_BRANCH="$(echo ${CIRCLE_TAG} | cut -d "/" -f2)"

    if \
        [ "${REAL_BRANCH}" == "${DEFAULT_SUITE}" ] && \
        ! git ls-remote --exit-code --heads origin refs/heads/${REAL_BRANCH} &>/dev/null
    then
        # "rolling" release, set REAL_BRANCH to droidian.
        REAL_BRANCH="droidian"
    fi
else
    REAL_BRANCH="${CIRCLE_BRANCH}"
fi

# Is this an official build?
if \
    [ "${CIRCLE_PROJECT_USERNAME}" == "droidian" ] || \
    [ "${CIRCLE_PROJECT_USERNAME}" == "droidian-releng" ] || \
    [ "${CIRCLE_PROJECT_USERNAME}" == "droidian-devices" ]
then
    OFFICIAL_BUILD="yes"
fi

cat > generated_config.yml <<EOF
version: 2.1

commands:
  armhf-setup:
    # Sets-up the environment to run armhf builds.
    # Ref: https://thegeeklab.de/posts/2020/09/run-an-arm32-docker-daemon-on-arm64-servers/
    steps:
      - run:
          name: Setup armhf environment
          command: |
            cat _escapeme_<<EOF | sudo tee /etc/apt/sources.list.d/docker-armhf.list
            deb [arch=armhf] https://download.docker.com/linux/ubuntu focal stable
            EOF
            sudo dpkg --add-architecture armhf
            sudo apt-get update
            sudo systemctl stop docker
            sudo systemctl stop containerd
            sudo systemctl disable docker
            sudo systemctl disable containerd
            sudo ln -sf /bin/true /usr/sbin/update-initramfs
            sudo apt-get install --yes docker-ce:armhf docker-ce-cli:armhf docker-ce-rootless-extras:armhf docker-compose-plugin:armhf
            sudo mkdir -p /etc/systemd/system/containerd.service.d
            sudo mkdir -p /etc/systemd/system/docker.service.d
            cat _escapeme_<<EOF | sudo tee /etc/systemd/system/containerd.service.d/arm32.conf
            [Service]
            ExecStart=
            ExecStart=/usr/bin/setarch linux32 -B /usr/bin/containerd
            EOF
            cat _escapeme_<<EOF | sudo tee /etc/systemd/system/docker.service.d/arm32.conf
            [Service]
            ExecStart=
            ExecStart=/usr/bin/setarch linux32 -B /usr/bin/dockerd -H unix:// --containerd=/run/containerd/containerd.sock
            EOF
            sudo systemctl daemon-reload
            sudo systemctl start containerd
            sudo systemctl start docker

  debian-build:
    parameters:
      suite:
        type: string
        default: "bookworm"
      architecture:
        type: string
        default: "arm64"
      full_build:
        type: string # yes or no
        default: "yes"
      extra_repos:
        type: string
        default: ""
      host_arch:
        type: string
        default: ""
    steps:
      - run:
          name: <<parameters.architecture>> build
          no_output_timeout: 60m
          command: |
            mkdir -p /tmp/buildd-results ; \\
            git clone -b "${REAL_BRANCH}" "${CIRCLE_REPOSITORY_URL//git@github.com:/https:\/\/github.com\/}" sources ; \\
            if [ -n "${CIRCLE_TAG}" ]; then \\
              cd sources ; \\
              git fetch --tags ; \\
              git checkout "${CIRCLE_TAG}" ; \\
              cd .. ; \\
            fi ; \\
            docker run \\
              --rm \\
              -e CI \\
              -e CIRCLECI \\
              -e CIRCLE_BRANCH="${REAL_BRANCH}" \\
              -e CIRCLE_SHA1 \\
              -e CIRCLE_TAG \\
              -e EXTRA_REPOS="<<parameters.extra_repos>>" \\
              -e RELENG_FULL_BUILD="<<parameters.full_build>>" \\
              -e RELENG_HOST_ARCH="<<parameters.host_arch>>" \\
              -v /tmp/buildd-results:/buildd \\
              -v ${PWD}/sources:/buildd/sources \\
              --cap-add=SYS_ADMIN \\
              --security-opt apparmor:unconfined \\
              --security-opt seccomp=unconfined \\
              quay.io/droidian/build-essential:<<parameters.suite>>-<<parameters.architecture>> \\
              /bin/sh -c "cd /buildd/sources ; releng-build-package"

  deploy-offline:
    steps:
      - store_artifacts:
          path: /tmp/buildd-results

  deploy:
    parameters:
      suite:
        type: string
        default: "bookworm"
      architecture:
        type: string
        default: "arm64"
    steps:
      - run:
          name: <<parameters.architecture>> deploy
          command: |
            docker run \\
              --rm \\
              -e CI \\
              -e CIRCLECI \\
              -e CIRCLE_BRANCH="${REAL_BRANCH}" \\
              -e CIRCLE_SHA1 \\
              -e CIRCLE_PROJECT_USERNAME \\
              -e CIRCLE_PROJECT_REPONAME \\
              -e CIRCLE_TAG \\
              -e GPG_STAGINGPRODUCTION_SIGNING_KEY="\$(echo \${GPG_STAGINGPRODUCTION_SIGNING_KEY} | base64 -d)" \\
              -e GPG_STAGINGPRODUCTION_SIGNING_KEYID \\
              -e INTAKE_SSH_USER \\
              -e INTAKE_SSH_KEY="\$(echo \${INTAKE_SSH_KEY} | base64 -d)" \\
              -v /tmp/buildd-results:/tmp/buildd-results \\
              quay.io/droidian/build-essential:<<parameters.suite>>-<<parameters.architecture>> \\
              /bin/sh -c "cd /tmp/buildd-results ; repo-droidian-sign.sh ; repo-droidian-deploy.sh"

jobs:
EOF

# Get source package name
SOURCE_NAME="$(grep 'Source:' debian/control | cut -d ' ' -f2-)"

# Determine which architectures to build
ARCHITECTURES="$(grep 'Architecture:' debian/control | cut -d ' ' -f2- | sed -s 's| |\n|g' | sort -u | grep -v all)" || true
if echo "${ARCHITECTURES}" | grep -q "any"; then
    ARCHITECTURES="${AVAILABLE_ARCHITECTURES}"
elif [ -z "${ARCHITECTURES}" ]; then
    # Default to amd64
    ARCHITECTURES="amd64"
fi

# Host arch specified?
HOST_ARCH="$(grep 'XS-Droidian-Host-Arch:' debian/control | head -n 1 | awk '{ print $2 }')" || true
BUILD_ON="$(grep 'XS-Droidian-Build-On:' debian/control | head -n 1 | awk '{ print $2 }')" || true
if [ -n "${HOST_ARCH}" ] && [ -n "${BUILD_ON}" ]; then
    ARCHITECTURES="${BUILD_ON}"
elif [ -n "${HOST_ARCH}" ]; then
    echo "Both XS-Droidian-Host-Arch and XS-Droidian-Build-On must be specified to allow crossbuilds" >&2
    exit 1
fi

# Retrieve EXTRA_REPOS
EXTRA_REPOS="$(grep 'XS-Droidian-Extra-Repos:' debian/control | cut -d ' ' -f2-)" || true

# Determine suite
# If the branch name is droidian, use $DEFAULT_SUITE
if [ "${REAL_BRANCH}" == "droidian" ]; then
    SUITE="${DEFAULT_SUITE}"
else
    SUITE="$(echo ${REAL_BRANCH} | cut -d/ -f2)"
fi

full_build="yes"
enabled_architectures=""
for arch in ${ARCHITECTURES}; do
    if ! echo "${AVAILABLE_ARCHITECTURES}" | grep -q ${arch}; then
        continue
    else
        enabled_architectures="${enabled_architectures} ${arch}"
    fi

    if [[ "${SOURCE_NAME}" == linux-android-* ]] && [ "${arch}" == "amd64" ]; then
        resource_class="large"
    elif [ "${arch}" == "amd64" ]; then
        resource_class="medium"
    else
        resource_class="arm.medium"
    fi

    if [ "${arch}" == "armhf" ]; then
        prepare="- armhf-setup"
    else
        prepare=""
    fi

    cat >> generated_config.yml <<EOF
  build-${arch}:
    machine:
      image: ubuntu-2004:current
      resource_class: ${resource_class}
    steps:
      ${prepare}
      - debian-build:
          suite: "${SUITE}"
          architecture: "${arch}"
          full_build: "${full_build}"
          host_arch: "${HOST_ARCH}"
          extra_repos: "${EXTRA_REPOS}"
EOF

    if [ "${OFFICIAL_BUILD}" == "yes" ]; then
        cat >> generated_config.yml <<EOF
      - deploy:
          suite: "${SUITE}"
          architecture: "${arch}"

EOF
    else
        cat >> generated_config.yml <<EOF
      - deploy-offline

EOF
    fi

    full_build="no"
done

cat >> generated_config.yml <<EOF
workflows:
  build:
    jobs:
EOF

for arch in ${enabled_architectures}; do
    cat >> generated_config.yml <<EOF
      - build-${arch}:
          filters:
            tags:
              only: /^droidian\/.*\/.*/
          context:
            - droidian-buildd
EOF
done

# Workaround for circleci import() misbehaviour
sed -i 's|_escapeme_<|\\<|g' generated_config.yml
