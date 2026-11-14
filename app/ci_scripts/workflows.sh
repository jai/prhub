#!/bin/zsh
# Sourced by the scripts here, and read by release/xcode-cloud.swift and release/cadence.mjs: PRHub's Xcode Cloud workflows, by id. A rename
# leaves an id alone; a workflow made again gets a new one, which goes here (App Store Connect → PRHub →
# Xcode Cloud).
release_workflow=2dee7663-233c-4612-8784-ef852b1cec1a
internal_workflow=A8C2D1A5-1530-49DD-A51F-4FABC66C6EC6
# The Mac's archive for the Internal group. A workflow of its own: Xcode Cloud's API cannot add an action to a workflow
# that has a TestFlight post-action, and an archive cannot be optional. release/cadence.mjs starts it with the phone's.
internal_mac_workflow=eb2bb5aa-850f-4d61-b48e-f3a54bebc8f0
