"""
blender_zombie_variants.py -- 3 real "evil zombie" variants built from 3
DISTINCT monster base models already sitting unused in this project (not 3
re-poses of the same soldier mesh), each with a real glowing-eye effect and
a contorted horror pose.

HONEST SCOPE NOTE: I checked every character model file in zombie/ headlessly
(bone counts, mesh names, material names) before writing this. Three real,
distinct, already-modeled monster meshes exist and are currently unused by
any scene:
  - zombie/Berserker/Demon T Wiezzorek.fbx  -- a horned demon, 8 separate
    mesh parts, 79 Mixamo bones. Crucially it has its OWN separate eye
    mesh object named "LP_Eyes_ring" -- so its eye-glow is a precise,
    real material swap on that exact object, not a guess.
  - zombie/TANK/Warrok W Kurniawan.fbx -- a bulky orc/troll creature,
    81 Mixamo bones, single combined mesh (no separate eye part).
  - zombie/shaman/Maw J Laygo.fbx -- a separate creature model,
    64 Mixamo bones, single combined mesh (no separate eye part).
All three use standard Mixamo bone names (mixamorig:Spine/Head/etc), so the
same pose-by-bone-substring logic works across all three real rigs.

For Warrok and Maw, since neither has a separate eye mesh/material, the
"glowing eyes" effect is a real but APPROXIMATE heuristic: select the mesh
vertices within a small radius of a point just in front of the Head bone
and assign them to a new emissive material slot. This will very likely
land on/around the face but not pixel-perfect on the eye sockets --
inspect it yourself in Blender and nudge EYE_HEURISTIC_RADIUS/EYE_OFFSET
per-variant below if the glow patch is misplaced. This is a real,
functioning technique (used for exactly this purpose in game art
pipelines when no eye UV mask exists), not a fabricated shortcut, but I
cannot verify visually whether it lands correctly, so you should check it.

I did NOT sculpt new geometry -- these are real, distinct, pre-existing
monster meshes (not the plain soldier body), posed into new contortions
with a real glow effect layered on. That is a genuine step up from
reposing one body 3 times, but it is still built from existing assets +
scripting, not hand-sculpted original detail.

WORKFLOW: run directly, no manual glTF export step needed --
this script imports each source .fbx from the project's zombie/ folder
directly (edit SOURCE_PATHS below only if you moved the project).
    blender --background --python blender_zombie_variants.py
Output: 3 .glb files in zombie_variants/, one per creature, ready to
import into Godot as new enemy scenes.
"""

import bpy
import math
import os

PROJECT_ROOT = r"G:\extra horde defense\horde-extra-branch\horde-beta-version-1"
OUTPUT_DIR = "zombie_variants"

VARIANTS = [
    {
        "name": "zombie_variant_demon",
        "source": PROJECT_ROOT + r"\zombie\Berserker\Demon T Wiezzorek.fbx",
        "glow_color": (0.9, 0.05, 0.02),   # hot red
        "eye_object_name": "LP_Eyes_ring",  # real, separate eye mesh -- precise
        "pose": [
            ("Spine",      (50, 0, 0)),     # hunched forward
            ("Spine1",     (15, 0, 10)),
            ("Head",       (-25, 15, 0)),   # head craned, twisted
            ("LeftArm",    (70, 0, -30)),
            ("RightArm",   (60, 0, 40)),
            ("LeftUpLeg",  (-30, 0, 0)),
            ("RightUpLeg", (-20, 0, 0)),
        ],
    },
    {
        "name": "zombie_variant_warrok",
        "source": PROJECT_ROOT + r"\zombie\TANK\Warrok W Kurniawan.fbx",
        "glow_color": (0.1, 0.7, 0.15),   # sickly green
        "eye_object_name": None,          # no separate eye mesh -- heuristic used
        "eye_heuristic_radius": 0.08,
        "eye_heuristic_forward_offset": 0.09,
        "pose": [
            ("Spine",      (-15, 0, 20)),  # arched, asymmetric lean
            ("Head",       (10, -30, 0)),
            ("LeftArm",    (150, 0, -10)),  # one arm thrown up
            ("RightArm",   (20, 0, 60)),
            ("Neck",       (0, 0, 20)),
        ],
    },
    {
        "name": "zombie_variant_maw",
        "source": PROJECT_ROOT + r"\zombie\shaman\Maw J Laygo.fbx",
        "glow_color": (0.55, 0.1, 0.85),   # unnatural violet
        "eye_object_name": None,
        "eye_heuristic_radius": 0.07,
        "eye_heuristic_forward_offset": 0.08,
        "pose": [
            ("Spine",      (10, 25, -25)),  # broken, asymmetric
            ("Head",       (35, -20, 15)),
            ("LeftArm",    (-30, 0, -40)),
            ("RightArm",   (100, 0, 30)),
            ("LeftLeg",    (60, 0, 0)),
        ],
    },
]

GLOW_ENERGY = 6.0  # emissive strength -- eyes should read as genuinely glowing


def find_bone(armature_obj, substring):
    substring = substring.lower()
    for bone in armature_obj.pose.bones:
        if substring in bone.name.lower():
            return bone
    return None


def apply_pose(armature_obj, pose_list):
    bpy.context.view_layer.objects.active = armature_obj
    bpy.ops.object.mode_set(mode="POSE")
    for bone_substr, euler_deg in pose_list:
        bone = find_bone(armature_obj, bone_substr)
        if bone is None:
            print(f"[variants] WARNING: no bone matching '{bone_substr}' -- skipped")
            continue
        bone.rotation_mode = "XYZ"
        bone.rotation_euler = tuple(math.radians(a) for a in euler_deg)
    bpy.ops.object.mode_set(mode="OBJECT")


def make_glow_material(name, color, energy):
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    emission = nt.nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = (*color, 1.0)
    emission.inputs["Strength"].default_value = energy
    output = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(emission.outputs["Emission"], output.inputs["Surface"])
    return mat


def glow_eye_object(root, eye_object_name, color, energy):
    """Precise path: the creature has its own separate eye mesh object."""
    eye_obj = None
    for obj in root.children_recursive if hasattr(root, "children_recursive") else _all_children(root):
        if obj.name == eye_object_name:
            eye_obj = obj
            break
    if eye_obj is None:
        print(f"[variants] WARNING: eye object '{eye_object_name}' not found -- glow skipped")
        return False
    glow_mat = make_glow_material(f"{eye_object_name}_glow", color, energy)
    eye_obj.data.materials.clear()
    eye_obj.data.materials.append(glow_mat)
    print(f"[variants] Applied precise eye glow to real object '{eye_object_name}'")
    return True


def glow_eye_heuristic(mesh_obj, armature_obj, color, energy, radius, forward_offset):
    """
    Approximate path for creatures with no separate eye mesh: select verts
    near the Head bone's forward-facing point and give them their own
    emissive material slot. Real technique, approximate placement --
    inspect in Blender and adjust radius/forward_offset if it misses.
    """
    head_bone = find_bone(armature_obj, "head")
    if head_bone is None:
        print("[variants] WARNING: no Head bone found -- eye heuristic skipped")
        return False

    head_world = armature_obj.matrix_world @ head_bone.head
    # Approximate "forward" as +Y in armature local space, converted to world.
    forward_world = armature_obj.matrix_world.to_3x3() @ __import__("mathutils").Vector((0, 1, 0))
    forward_world.normalize()
    eye_center = head_world + forward_world * forward_offset

    glow_mat = make_glow_material(f"{mesh_obj.name}_eye_glow_heuristic", color, energy)
    mesh_obj.data.materials.append(glow_mat)
    glow_slot_index = len(mesh_obj.data.materials) - 1

    bpy.context.view_layer.objects.active = mesh_obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="DESELECT")
    bpy.ops.object.mode_set(mode="OBJECT")

    world_matrix = mesh_obj.matrix_world
    selected_count = 0
    for v in mesh_obj.data.vertices:
        world_pos = world_matrix @ v.co
        if (world_pos - eye_center).length <= radius:
            v.select = True
            selected_count += 1

    if selected_count == 0:
        print(f"[variants] WARNING: eye heuristic selected 0 vertices for "
              f"{mesh_obj.name} -- radius/offset likely needs adjusting")
        return False

    bpy.ops.object.mode_set(mode="EDIT")
    bpy.context.tool_settings.mesh_select_mode = (True, False, False)
    mesh_obj.active_material_index = glow_slot_index
    bpy.ops.object.material_slot_assign()
    bpy.ops.object.mode_set(mode="OBJECT")
    print(f"[variants] Eye-glow heuristic selected {selected_count} vertices "
          f"near the head on {mesh_obj.name} (approximate -- verify visually)")
    return True


def _all_children(node):
    result = []
    for child in node.children:
        result.append(child)
        result.extend(_all_children(child))
    return result


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    for variant in VARIANTS:
        src = variant["source"]
        if not os.path.isfile(src):
            print(f"[variants] WARNING: source not found, skipping: {src}")
            continue

        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.fbx(filepath=src)

        armature_obj = next((o for o in bpy.context.scene.objects if o.type == "ARMATURE"), None)
        mesh_objects = [o for o in bpy.context.scene.objects if o.type == "MESH"]

        if armature_obj is None:
            print(f"[variants] WARNING: no armature in {src} -- pose skipped")
        else:
            apply_pose(armature_obj, variant["pose"])

        if variant["eye_object_name"]:
            glowed = False
            for obj in mesh_objects:
                if obj.name == variant["eye_object_name"]:
                    glow_mat = make_glow_material(
                        f"{obj.name}_glow", variant["glow_color"], GLOW_ENERGY)
                    obj.data.materials.clear()
                    obj.data.materials.append(glow_mat)
                    glowed = True
                    print(f"[variants] {variant['name']}: precise eye glow on '{obj.name}'")
                    break
            if not glowed:
                print(f"[variants] WARNING: eye object '{variant['eye_object_name']}' "
                      f"not found in {src}")
        else:
            main_mesh = max(mesh_objects, key=lambda o: len(o.data.vertices))
            glow_eye_heuristic(
                main_mesh, armature_obj, variant["glow_color"], GLOW_ENERGY,
                variant["eye_heuristic_radius"], variant["eye_heuristic_forward_offset"])

        out_path = os.path.join(OUTPUT_DIR, variant["name"] + ".glb")
        bpy.ops.export_scene.gltf(
            filepath=out_path,
            export_format="GLB",
            export_apply=True,
            export_yup=True,
            export_animations=True,
            export_skins=True,
        )
        print(f"[variants] Wrote {out_path}")

    print(f"[variants] Done -- {len(VARIANTS)} variant(s) in {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
