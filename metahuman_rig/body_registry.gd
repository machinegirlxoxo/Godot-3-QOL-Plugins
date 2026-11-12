tool
extends Reference
# Shared between the body rig and the RigLogic binders: skeleton instance id -> [version, {joint name: true}] of the
# joints the body rig owns (the face rig must not reset them). A script constant Dictionary is one shared object.

const DATA = {}
