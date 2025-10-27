#!/usr/bin/env bats

@test "deploy-openstack.sh syntax" {
    run bash -n "./2024.2 (Dalmatian)/deploy-openstack.sh"
    [ "$status" -eq 0 ]
}
