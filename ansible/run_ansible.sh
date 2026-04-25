#!/bin/bash
source /etc/os-release
export UV_INSTALL_DIR=/config/venv/${ID^}_${VERSION_ID}_$(uname -m)/
export VENV_PATH=${UV_INSTALL_DIR}/oci
export ANSIBLE_HOST_KEY_CHECKING=False
$VENV_PATH/bin/ansible-playbook -i inventory playbook.yaml
