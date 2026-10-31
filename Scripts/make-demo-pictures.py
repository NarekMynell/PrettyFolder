# Renders the pictures the README's animations put on folders.
#
#   /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
#       --python Scripts/make-demo-pictures.py -- docs/media/pictures [name ...]
#
# Each picture is a small toy-like 3D scene, rendered with Cycles on a transparent
# background and then laid over a flat color with ImageMagick (`magick`).

import math
import os
import random
import shutil
import subprocess
import sys

import bmesh
import bpy
from mathutils import Vector

WIDTH, HEIGHT = 1200, 800


# MARK: - Scene setup

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.render.resolution_x = WIDTH
    scene.render.resolution_y = HEIGHT
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.cycles.samples = 128
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = 'Khronos PBR Neutral'
    use_gpu(scene)

    world = bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.8, 0.82, 0.86, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.55
    return scene


def use_gpu(scene):
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for device in prefs.devices:
            device.use = True
        scene.cycles.device = "GPU"
    except Exception:
        scene.cycles.device = "CPU"


def material(name, color, roughness=0.35, coat=0.0, subsurface=0.0, emission=0.0, metallic=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*srgb(color), 1)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.08
    if subsurface:
        bsdf.inputs["Subsurface Weight"].default_value = subsurface
        bsdf.inputs["Subsurface Radius"].default_value = (0.4, 0.3, 0.2)
        bsdf.inputs["Subsurface Scale"].default_value = 0.08
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*srgb(color), 1)
        bsdf.inputs["Emission Strength"].default_value = emission
    return mat


def srgb(hex_color):
    """A #RRGGBB color as linear RGB, which is what Blender's color sockets take."""
    value = hex_color.lstrip("#")
    channels = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels)


def finish(obj, mat, subdivisions=2, smooth=True):
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    if smooth:
        for polygon in obj.data.polygons:
            polygon.use_smooth = True
    if subdivisions:
        modifier = obj.modifiers.new("Smooth", 'SUBSURF')
        modifier.levels = subdivisions
        modifier.render_levels = subdivisions
    return obj


def sphere(name, location, scale, mat, rotation=(0, 0, 0), subdivisions=1):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=64, ring_count=32, radius=1, location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = scale
    return finish(obj, mat, subdivisions)


def floor():
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
    plane = bpy.context.active_object
    plane.is_shadow_catcher = True
    return plane


def light(name, location, target, power, size, color=(1, 1, 1)):
    data = bpy.data.lights.new(name, 'AREA')
    data.energy = power
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    look_at(obj, target)
    return obj


def studio_lights(target=(0, 0, 1), key=900, rim=500):
    light("Key", (-4, -5, 7), target, key, 6)
    light("Fill", (6, -4, 3), target, key * 0.35, 8)
    light("Rim", (2, 6, 5), target, rim, 4)


def camera(location, target, lens=60):
    data = bpy.data.cameras.new("Camera")
    data.lens = lens
    obj = bpy.data.objects.new("Camera", data)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    look_at(obj, target)
    bpy.context.scene.camera = obj
    return obj


def look_at(obj, target):
    direction = Vector(target) - obj.location
    obj.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()


# MARK: - Pictures

def rubber_duck():
    yellow = material("Duck", "#FFCC1A", roughness=0.28, coat=0.6, subsurface=0.15)
    orange = material("Beak", "#FF7A1A", roughness=0.3, coat=0.5)
    black = material("Eye", "#14110F", roughness=0.15, coat=1)
    white = material("Shine", "#FFFFFF", emission=3)

    sphere("Body", (0, 0, 0.78), (1.3, 0.98, 0.8), yellow)
    sphere("Tail", (-1.05, 0, 1.12), (0.5, 0.42, 0.3), yellow, rotation=(0, math.radians(-35), 0))
    sphere("Wing", (-0.1, -0.86, 0.95), (0.62, 0.18, 0.36), yellow, rotation=(math.radians(8), math.radians(-12), 0))
    sphere("Head", (0.62, 0, 1.78), (0.66, 0.66, 0.64), yellow)
    sphere("Beak", (1.22, 0, 1.64), (0.44, 0.34, 0.13), orange, rotation=(0, math.radians(-8), 0))
    for side in (-1, 1):
        sphere("Eye", (1.05, side * 0.36, 2.04), (0.14, 0.14, 0.17), black)
        sphere("Shine", (1.13, side * 0.43, 2.1), (0.04, 0.04, 0.04), white, subdivisions=0)
    floor()
    studio_lights(target=(0.2, 0, 1.1))
    camera((3.6, -7.8, 2.9), (0.15, 0, 1.15), lens=58)
    return "#9ED8FF"


def donut():
    dough = material("Dough", "#E2A66B", roughness=0.6, subsurface=0.2)
    icing = material("Icing", "#FF7EB6", roughness=0.18, coat=1, subsurface=0.1)

    bpy.ops.mesh.primitive_torus_add(major_radius=1, minor_radius=0.5, major_segments=96, minor_segments=48, location=(0, 0, 0.5))
    finish(bpy.context.active_object, dough)

    # The icing: the top of a slightly fatter torus, cut along a wavy line so it drips.
    bpy.ops.mesh.primitive_torus_add(major_radius=1, minor_radius=0.53, major_segments=192, minor_segments=96, location=(0, 0, 0.5))
    top = bpy.context.active_object
    mesh = bmesh.new()
    mesh.from_mesh(top.data)
    doomed = []
    for vertex in mesh.verts:
        angle = math.atan2(vertex.co.y, vertex.co.x)
        drip = 0.05 * math.sin(angle * 7) + 0.04 * math.sin(angle * 13 + 1)
        if vertex.co.z < 0.04 + drip:
            doomed.append(vertex)
    bmesh.ops.delete(mesh, geom=doomed, context='VERTS')
    mesh.to_mesh(top.data)
    mesh.free()
    solidify = top.modifiers.new("Thickness", 'SOLIDIFY')
    solidify.thickness = 0.04
    finish(top, icing)

    # Sprinkles on top of the icing.
    random.seed(7)
    colors = ["#FFFFFF", "#FFE04D", "#4DD2FF", "#9B6BFF", "#FF9A3D", "#5BE38A"]
    sprinkle_materials = [material(f"Sprinkle{i}", c, roughness=0.3, coat=0.8) for i, c in enumerate(colors)]
    for _ in range(140):
        around = random.uniform(0, 2 * math.pi)
        up = random.uniform(math.radians(15), math.radians(165))
        radius = 0.56
        center = Vector((math.cos(around), math.sin(around), 0))
        normal = Vector((math.cos(up) * math.cos(around), math.cos(up) * math.sin(around), math.sin(up)))
        position = center + normal * radius + Vector((0, 0, 0.5))
        bpy.ops.mesh.primitive_cylinder_add(radius=0.022, depth=0.13, vertices=12, location=position)
        sprinkle = bpy.context.active_object
        # Lying on the icing, pointing any which way.
        direction = normal.cross(Vector((random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-1, 1)))).normalized()
        sprinkle.rotation_euler = direction.to_track_quat('Z', 'Y').to_euler()
        finish(sprinkle, random.choice(sprinkle_materials), subdivisions=1)
    floor()
    studio_lights(target=(0, 0, 0.5), key=800)
    camera((0, -4.6, 4.1), (0, 0.15, 0.25), lens=50)
    return "#A6EED6"


def cool_monkey():
    fur = material("Monkey", "#C9844F", roughness=0.45, subsurface=0.25)
    glasses = material("Glasses", "#0E0E12", roughness=0.05, coat=1)
    frame = material("Frame", "#1A1A1F", roughness=0.25)

    bpy.ops.mesh.primitive_monkey_add(size=2, location=(0, 0, 1.1))
    monkey = finish(bpy.context.active_object, fur, subdivisions=2)
    monkey.rotation_euler = (math.radians(-6), 0, 0)

    # Sunglasses: two rounded lenses and a bridge, just in front of the eyes.
    bpy.context.view_layer.update()
    for side in (-1, 1):
        bpy.ops.mesh.primitive_cylinder_add(radius=0.36, depth=0.08, vertices=64, location=(side * 0.47, -0.93, 1.38), rotation=(math.radians(90), 0, 0))
        lens = bpy.context.active_object
        lens.scale = (1.2, 0.9, 1)
        bevel = lens.modifiers.new("Round", 'BEVEL')
        bevel.width = 0.03
        bevel.segments = 4
        finish(lens, glasses, subdivisions=0)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.04, depth=0.32, vertices=24, location=(0, -0.97, 1.47), rotation=(0, math.radians(90), 0))
    finish(bpy.context.active_object, frame, subdivisions=0)
    for obj in [o for o in bpy.context.scene.objects if o.type == 'MESH' and o != monkey]:
        obj.parent = monkey
        obj.matrix_parent_inverse = monkey.matrix_world.inverted()
    floor()
    studio_lights(target=(0, 0, 1.2), key=900)
    camera((0.6, -8.6, 1.9), (0, 0, 1.12), lens=60)
    return "#C49BFF"


def rocket():
    white = material("Hull", "#F4F5F8", roughness=0.25, coat=0.8)
    red = material("Red", "#FF4F5E", roughness=0.25, coat=0.8)
    glass = material("Window", "#5CC8FF", roughness=0.05, coat=1, emission=0.4)
    metal = material("Metal", "#C9CED8", roughness=0.2, metallic=1)
    flame = material("Flame", "#FF7A1A", emission=2.2)
    core = material("Core", "#FFD84D", emission=3.5)
    smoke = material("Smoke", "#FFFFFF", roughness=0.8)
    star = material("Star", "#FFF6C8", emission=4)

    # The hull: a profile turned around the axis.
    profile = [(0.0, -1.3), (0.42, -1.3), (0.6, -0.9), (0.66, -0.2), (0.62, 0.5), (0.45, 1.1), (0.2, 1.55), (0.0, 1.7)]
    mesh = bpy.data.meshes.new("Hull")
    mesh.from_pydata([(r, 0, z) for r, z in profile], [(i, i + 1) for i in range(len(profile) - 1)], [])
    hull = bpy.data.objects.new("Hull", mesh)
    bpy.context.collection.objects.link(hull)
    screw = hull.modifiers.new("Turn", 'SCREW')
    screw.steps = 96
    screw.render_steps = 96
    finish(hull, white, subdivisions=2)

    # Red nose: the top of the same profile, a little bigger.
    nose_profile = [(0.465, 1.05), (0.25, 1.52), (0.0, 1.72)]
    mesh = bpy.data.meshes.new("Nose")
    mesh.from_pydata([(r, 0, z) for r, z in nose_profile], [(0, 1), (1, 2)], [])
    nose = bpy.data.objects.new("Nose", mesh)
    bpy.context.collection.objects.link(nose)
    screw = nose.modifiers.new("Turn", 'SCREW')
    screw.steps = 96
    screw.render_steps = 96
    solidify = nose.modifiers.new("Thickness", 'SOLIDIFY')
    solidify.thickness = 0.03
    finish(nose, red, subdivisions=2)

    # Window.
    bpy.ops.mesh.primitive_torus_add(major_radius=0.25, minor_radius=0.05, location=(0, -0.64, 0.35), rotation=(math.radians(90), 0, 0))
    finish(bpy.context.active_object, metal)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.23, depth=0.06, vertices=48, location=(0, -0.63, 0.35), rotation=(math.radians(90), 0, 0))
    finish(bpy.context.active_object, glass, subdivisions=0)

    # Three swept fins.
    outline = [(0.45, -1.3), (1.05, -1.55), (1.0, -0.95), (0.55, -0.45)]
    for index in range(3):
        angle = index * 2 * math.pi / 3 + math.radians(30)
        mesh = bpy.data.meshes.new("Fin")
        depth = 0.07
        vertices = [(x, y, z) for x, z in outline for y in (-depth, depth)]
        faces = [(0, 2, 4, 6), (1, 7, 5, 3)] + [(2 * i, 2 * i + 1, 2 * ((i + 1) % 4) + 1, 2 * ((i + 1) % 4)) for i in range(4)]
        mesh.from_pydata(vertices, [], faces)
        mesh.validate()
        fin = bpy.data.objects.new("Fin", mesh)
        bpy.context.collection.objects.link(fin)
        fin.rotation_euler = (0, 0, angle)
        bevel = fin.modifiers.new("Round", 'BEVEL')
        bevel.width = 0.04
        bevel.segments = 3
        finish(fin, red, subdivisions=1)

    # Flame.
    bpy.ops.mesh.primitive_cone_add(radius1=0.42, radius2=0.0, depth=1.2, vertices=48, location=(0, 0, -1.85), rotation=(math.radians(180), 0, 0))
    finish(bpy.context.active_object, flame)
    bpy.ops.mesh.primitive_cone_add(radius1=0.24, radius2=0.0, depth=0.7, vertices=48, location=(0, 0, -1.6), rotation=(math.radians(180), 0, 0))
    finish(bpy.context.active_object, core)

    # Puffs of smoke behind the flame.
    for offset, size in [(-2.5, 0.3), (-2.9, 0.38)]:
        sphere("Smoke", (0.08 * offset, 0, offset), (size, size, size * 0.9), smoke)

    group = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    pivot = bpy.data.objects.new("Rocket", None)
    bpy.context.collection.objects.link(pivot)
    for obj in group:
        obj.parent = pivot
    pivot.rotation_euler = (math.radians(-12), math.radians(38), 0)
    pivot.location = (0.55, 0, 0.55)

    # Stars far behind.
    random.seed(3)
    for _ in range(46):
        size = random.uniform(0.018, 0.05)
        sphere("Star", (random.uniform(-7, 7), 9, random.uniform(-4, 4.5)), (size, size, size), star, subdivisions=0)
    studio_lights(target=(0, 0, 0.2), key=1000, rim=900)
    camera((0, -8.5, 0.6), (0, 0, 0.12), lens=46)
    return "#22306B"


def ghost():
    body = material("Ghost", "#FFFFFF", roughness=0.35, subsurface=0.3)
    black = material("Face", "#18141F", roughness=0.2, coat=1)
    pink = material("Cheek", "#FF8FB1", roughness=0.6)

    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=64, radius=1, location=(0, 0, 0))
    ghost = bpy.context.active_object
    mesh = bmesh.new()
    mesh.from_mesh(ghost.data)
    for vertex in mesh.verts:
        if vertex.co.z < 0:
            # The lower half becomes a skirt that flares a little and ends in a wavy hem.
            depth = -vertex.co.z
            angle = math.atan2(vertex.co.y, vertex.co.x)
            ring = math.hypot(vertex.co.x, vertex.co.y)
            radius = max(ring, 0.98 if depth < 0.95 else ring) * (1 + 0.14 * depth)
            if ring > 0:
                vertex.co.x *= radius / ring
                vertex.co.y *= radius / ring
            vertex.co.z = -1.25 * depth + 0.2 * math.sin(angle * 6) * depth ** 4
    mesh.to_mesh(ghost.data)
    mesh.free()
    ghost.scale = (1, 1, 1.1)
    ghost.location = (0, 0, 1.75)
    finish(ghost, body, subdivisions=1)

    for side in (-1, 1):
        sphere("Eye", (side * 0.34, -0.92, 2.05), (0.13, 0.08, 0.2), black)
        sphere("Cheek", (side * 0.6, -0.8, 1.78), (0.14, 0.05, 0.09), pink)
        sphere("Arm", (side * 1.12, -0.1, 1.45), (0.32, 0.22, 0.2), body, rotation=(0, math.radians(side * 30), 0))
    sphere("Mouth", (0, -0.98, 1.74), (0.12, 0.06, 0.15), black)
    floor()
    studio_lights(target=(0, 0, 1.5), key=650, rim=700)
    camera((0.9, -7.6, 2.4), (0, 0, 1.35), lens=56)
    return "#FF9A4A"


PICTURES = {
    "rubber-duck": rubber_duck,
    "donut": donut,
    "cool-monkey": cool_monkey,
    "rocket": rocket,
    "ghost": ghost,
}


def render(name, output):
    background = PICTURES[name]()
    layer = os.path.join(output, f"{name}-layer.png")
    bpy.context.scene.render.filepath = layer
    bpy.ops.render.render(write_still=True)
    final = os.path.join(output, f"{name}.jpg")
    magick = shutil.which("magick") or "/opt/homebrew/bin/magick"
    subprocess.run(
        [magick, "-size", f"{WIDTH}x{HEIGHT}", f"xc:{background}", layer, "-composite", "-strip", "-quality", "90", final],
        check=True,
    )
    os.remove(layer)
    print(f"Wrote {final}")


def main():
    arguments = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if not arguments:
        sys.exit("Usage: blender -b --factory-startup --python make-demo-pictures.py -- <output folder> [name ...]")
    output = os.path.abspath(arguments[0])
    os.makedirs(output, exist_ok=True)
    for name in arguments[1:] or PICTURES:
        reset()
        render(name, output)


main()
