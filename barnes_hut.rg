import "regent"
require("quad_tree")

local assert = regentlib.assert
local c = regentlib.c
local cos = regentlib.cos(float)
local pow = regentlib.pow(float)
local sin = regentlib.sin(float)
local sqrt = regentlib.sqrt(float)

local cmath = terralib.includec("math.h")
local cstring = terralib.includec("string.h")
local std = terralib.includec("stdlib.h")

local BarnesHitIO = require("barnes_hut_io")
local QuadTreeSizer = require("quad_tree_sizer")

rawset(_G, "drand48", std.drand48)
rawset(_G, "srand48", std.srand48)

local gee = 100
local delta = 0.1
local theta = 0.5
local epsilon = 0.00001

struct Config {
  num_bodies : uint,
  random_seed : uint,
  iterations : uint,
  verbose : bool,
  output_dir : rawstring,
  output_dir_set : bool,
  parallelism : uint,
  N : uint,
  leaf_size : uint
  fixed_partition_size : uint,
}

fspace body {
  {mass_x, mass_y, speed_x, speed_y, mass, force_x, force_y} : double,
  sector : int1d,
  {color, index} : uint,
}

fspace boundary {
  {min_x, min_y, max_x, max_y} : double
}

terra parse_input_args(conf : Config)
  var args = c.legion_runtime_get_input_args()
  for i = 0, args.argc do
    if cstring.strcmp(args.argv[i], "-o") == 0 then
      i = i + 1
      conf.output_dir = args.argv[i]
      conf.output_dir_set = true
    elseif cstring.strcmp(args.argv[i], "-b") == 0 then
      i = i + 1
      conf.num_bodies = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-s") == 0 then
      i = i + 1
      conf.random_seed = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-i") == 0 then
      i = i + 1
      conf.iterations = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-p") == 0 then
      i = i + 1
      conf.parallelism = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-N") == 0 then
      i = i + 1
      conf.N = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-l") == 0 then
      i = i + 1
      conf.leaf_size = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-x") == 0 then
      i = i + 1
      conf.fixed_partition_size = std.atoi(args.argv[i])
    elseif cstring.strcmp(args.argv[i], "-v") == 0 then
      conf.verbose = true
    end
  end
  return conf
end

task init_stars(bodies : region(ispace(ptr), body), num : uint, max_radius : double, cx : double, cy : double, sx : double, sy : double, color : uint, partition_start : uint, partition_size : uint)
  where
  writes(bodies)
do
  var total_m = 1.5 * num
  var cube_max_radius = max_radius * max_radius * max_radius

  var index = partition_start * partition_size
  for body in bodies do
    var angle = drand48() * 2 * cmath.M_PI
    var radius = 25 + max_radius * drand48()

    body.mass_x = cx + radius * sin(angle)
    body.mass_y = cy + radius * cos(angle)

    var speed = sqrt(gee * num / radius + gee * total_m * radius * radius / cube_max_radius)

    body.speed_x = sx + speed * sin(angle + cmath.M_PI / 2)
    body.speed_y = sy + speed * cos(angle + cmath.M_PI / 2)
    body.mass = 1.0 + drand48()
    body.color = color
    body.index = index

    index += 1
  end
end

task init_2_galaxies(bodies : region(body), conf : Config)
  where writes(bodies)
do
  srand48(conf.random_seed)

  var bodies_partition = partition(equal, bodies, ispace(int1d, 8))

  var num1 = conf.num_bodies / 8
  var num2 = conf.num_bodies - num1

  init_stars(bodies_partition[0], num1, 300, 0, 0, 0, 0, 1, 0, num1)

  __demand(__parallel)
  for i = 1, 8 do
    init_stars(bodies_partition[i], num2, 350, -1800, -1200, 0, 0, 2, i, num1)
  end

  bodies[0].mass_x = 0
  bodies[0].mass_y = 0
  bodies[0].speed_x = 0
  bodies[0].speed_y = 0
  bodies[0].mass = num1
  bodies[0].color = 0

  bodies[num1].mass_x = -1800
  bodies[num1].mass_y = -1200
  bodies[num1].speed_x = 0
  bodies[num1].speed_y = 0
  bodies[num1].mass = num2
  bodies[num1].color = 0
end

task print_bodies_initial(bodies : region(body))
  where reads(bodies)
do
  c.printf("Initial bodies:\n") 
  for body in bodies do
    c.printf("%d: x: %f, y: %f, speed_x: %f, speed_y: %f, mass: %f\n",
    body.index, body.mass_x, body.mass_y, body.speed_x, body.speed_y, body.mass)
  end
  c.printf("\n") 
end

task print_update(iteration : uint, bodies : region(body), sector_precision : uint)
  where reads(bodies)
do
  c.printf("Iteration %d\n", iteration + 1)
  for body in bodies do
    var sector_x = body.sector % sector_precision
    var sector_y: int64 = cmath.floor(body.sector / sector_precision)

    c.printf("%d: x: %f, y: %f, speed_x: %f, speed_y: %f, sector: (%d, %d)\n",
    body.index, body.mass_x, body.mass_y, body.speed_x, body.speed_y, sector_x, sector_y)
  end
  c.printf("\n") 
end

task update_boundaries(bodies : region(body), boundaries : region(boundary))
  where
  reads(bodies.{mass_x, mass_y}),
  reads(boundaries),
  reduces min(boundaries.{min_x, min_y}),
  reduces max(boundaries.{max_x, max_y})
do
  for body in bodies do
    boundaries[0].min_x min = min(body.mass_x, boundaries[0].min_x)
    boundaries[0].min_y min = min(body.mass_y, boundaries[0].min_y)
    boundaries[0].max_x max = max(body.mass_x, boundaries[0].max_x)
    boundaries[0].max_y max = max(body.mass_y, boundaries[0].max_y)
  end
end

task assign_sectors(bodies : region(body), min_x : double, min_y : double, size : double, sector_precision : uint)
  where
  reads(bodies.{mass_x, mass_y, sector}),
  writes(bodies.sector)
do
  for body in bodies do
    var sector_x : int64 = cmath.floor((body.mass_x - min_x) / (size / sector_precision))
    if (sector_x >= sector_precision) then
      sector_x = sector_x - 1
    end

    var sector_y: int64 = cmath.floor((body.mass_y - min_y) / (size / sector_precision))
    if (sector_y >= sector_precision) then
      sector_y = sector_y - 1
    end

    body.sector = sector_x + sector_y * sector_precision
  end
end

task size_quad(bodies : region(body), max_size : region(uint), min_x : double, min_y : double, size : double, sector_precision : uint, leaf_size : uint, sector : int1d)
  where reads(bodies.{mass_x, mass_y, index}),
  reads (max_size),
  reduces max(max_size)
do
  var chunk = create_quad_chunk(512)
  var sector_x = sector % sector_precision
  var sector_y: int64 = cmath.floor(sector / sector_precision)
  var center_x = min_x + (sector_x + 0.5) * size / sector_precision
  var center_y = min_y + (sector_y + 0.5) * size / sector_precision

  var root = init_placeholder(chunk)
  root.center_x = center_x
  root.center_y = center_y
  root.size = size / sector_precision
  root.type = 2

  for body in bodies do
    var body_quad = init_placeholder(chunk)
    body_quad.mass_x = body.mass_x
    body_quad.mass_y = body.mass_y
    body_quad.type = 1
    add_placeholder(root, body_quad, chunk, leaf_size)
  end

  var num_quads = count(chunk, true)
  max_size[0] max = max(max_size[0], num_quads)
end

task build_quad(bodies : region(body), quads : region(ispace(int1d), quad), min_x : double, min_y : double, size : double, sector_precision : uint, leaf_size : uint, sector : int1d, partition_size: uint)
  where
  reads(bodies.{mass_x, mass_y, mass, index}),
  reads writes(quads)
do
  var sector_x = sector % sector_precision
  var sector_y: int64 = cmath.floor(sector / sector_precision)

  var index = sector * partition_size
  var root_index = index
  assert(quads[root_index].type == 0, "root already allocated")
  quads[root_index].center_x = min_x + (sector_x + 0.5) * size / sector_precision
  quads[root_index].center_y = min_y + (sector_y + 0.5) * size / sector_precision
  quads[root_index].size = size / sector_precision
  quads[root_index].type = 2
  
  var parent_list : int1d[1024]
  var child_list : int1d[1024]
  var traverse_index = 0

  for body in bodies do
    index = index + 1
    assert(quads[index].type == 0, "body already allocated")
    quads[index].mass_x = body.mass_x
    quads[index].mass_y = body.mass_y
    quads[index].mass = body.mass
    quads[index].total = 1
    quads[index].type = 1
    quads[index].index = body.index

    parent_list[traverse_index] = root_index
    child_list[traverse_index] = index
    
    while traverse_index >= 0 do  
      var parent_index = parent_list[traverse_index]
      var child_index = child_list[traverse_index]
      traverse_index = traverse_index - 1

      var half_size = quads[parent_index].size / 2
      if quads[child_index].mass_x <= quads[parent_index].center_x then
        if quads[child_index].mass_y <= quads[parent_index].center_y then
          if quads[parent_index].sw == -1 then
            quads[child_index].leaf_count = 1
            quads[parent_index].sw = child_index
          elseif quads[quads[parent_index].sw].type == 1 then
            if quads[quads[parent_index].sw].leaf_count < leaf_size then
              quads[child_index].leaf_count = quads[quads[parent_index].sw].leaf_count + 1
              quads[child_index].next_in_leaf = quads[parent_index].sw
              quads[parent_index].sw = child_index
            else
              index += 1
              assert(quads[index].type == 0, "region already allocated")
              quads[index].type = 2
              quads[index].center_x = quads[parent_index].center_x - half_size / 2
              quads[index].center_y = quads[parent_index].center_y - half_size / 2
              quads[index].size = half_size
              quads[parent_index].sw = index

              var current = quads[parent_index].sw
              while current ~= -1 do
                var next_in_leaf = quads[current].next_in_leaf
                quads[current].next_in_leaf = -1
                traverse_index += 1
                parent_list[traverse_index] = index
                child_list[traverse_index] = current
                current = next_in_leaf
              end

              traverse_index += 1
              parent_list[traverse_index] = index
              child_list[traverse_index] = child_index              
            end
          else
            traverse_index += 1
            parent_list[traverse_index] = quads[parent_index].sw
            child_list[traverse_index] = child_index             
          end
        else
          if quads[parent_index].nw == -1 then
            quads[child_index].leaf_count = 1
            quads[parent_index].nw = child_index
          elseif quads[quads[parent_index].nw].type == 1 then
            if quads[quads[parent_index].nw].leaf_count < leaf_size then
              quads[child_index].leaf_count = quads[quads[parent_index].nw].leaf_count + 1
              quads[child_index].next_in_leaf = quads[parent_index].nw
              quads[parent_index].nw = child_index
            else
              index += 1
              assert(quads[index].type == 0, "region already allocated")
              quads[index].type = 2
              quads[index].center_x = quads[parent_index].center_x - half_size / 2
              quads[index].center_y = quads[parent_index].center_y + half_size / 2
              quads[index].size = half_size
              quads[parent_index].nw = index

              var current = quads[parent_index].nw
              while current ~= -1 do
                var next_in_leaf = quads[current].next_in_leaf
                quads[current].next_in_leaf = -1
                traverse_index += 1
                parent_list[traverse_index] = index
                child_list[traverse_index] = current
                current = next_in_leaf
              end

              traverse_index += 1
              parent_list[traverse_index] = index
              child_list[traverse_index] = child_index 
            end
          else
            traverse_index += 1
            parent_list[traverse_index] = quads[parent_index].nw
            child_list[traverse_index] = child_index 
          end      
        end
      else
        if quads[child_index].mass_y <= quads[parent_index].center_y then
          if quads[parent_index].se == -1 then
            quads[child_index].leaf_count = 1
            quads[parent_index].se = child_index
          elseif quads[quads[parent_index].se].type == 1 then
            if quads[quads[parent_index].se].leaf_count < leaf_size then
              quads[child_index].leaf_count = quads[quads[parent_index].se].leaf_count + 1
              quads[child_index].next_in_leaf = quads[parent_index].se
              quads[parent_index].se = child_index
            else
              index += 1
              assert(quads[index].type == 0, "region already allocated")
              quads[index].type = 2
              quads[index].center_x = quads[parent_index].center_x + half_size / 2
              quads[index].center_y = quads[parent_index].center_y - half_size / 2
              quads[index].size = half_size
              quads[parent_index].se = index

              var current = quads[parent_index].se
              while current ~= -1 do
                var next_in_leaf = quads[current].next_in_leaf
                quads[current].next_in_leaf = -1
                traverse_index += 1
                parent_list[traverse_index] = index
                child_list[traverse_index] = current
                current = next_in_leaf
              end

              traverse_index += 1
              parent_list[traverse_index] = index
              child_list[traverse_index] = child_index 
            end
          else
            traverse_index += 1
            parent_list[traverse_index] = quads[parent_index].se
            child_list[traverse_index] = child_index 
          end 
        else
          if quads[parent_index].ne == -1 then
            quads[child_index].leaf_count = 1
            quads[parent_index].ne = child_index
          elseif quads[quads[parent_index].ne].type == 1 then
            if quads[quads[parent_index].ne].leaf_count < leaf_size then
              quads[child_index].leaf_count = quads[quads[parent_index].ne].leaf_count + 1
              quads[child_index].next_in_leaf = quads[parent_index].ne
              quads[parent_index].ne = child_index
            else
              index += 1
              assert(quads[index].type == 0, "region already allocated")
              quads[index].type = 2
              quads[index].center_x = quads[parent_index].center_x + half_size / 2
              quads[index].center_y = quads[parent_index].center_y + half_size / 2
              quads[index].size = half_size
              quads[parent_index].ne = index

              var current = quads[parent_index].ne
              while current ~= -1 do
                var next_in_leaf = quads[current].next_in_leaf
                quads[current].next_in_leaf = -1
                traverse_index += 1
                parent_list[traverse_index] = index
                child_list[traverse_index] = current
                current = next_in_leaf
              end

              traverse_index += 1
              parent_list[traverse_index] = index
              child_list[traverse_index] = child_index 
            end
          else
            traverse_index += 1
            parent_list[traverse_index] = quads[parent_index].se
            child_list[traverse_index] = child_index
          end     
        end
      end

      var old_mass = quads[parent_index].mass
      var new_mass = quads[parent_index].mass + quads[child_index].mass
      quads[parent_index].mass_x = (quads[parent_index].mass_x * old_mass + quads[child_index].mass_x * quads[child_index].mass) / new_mass
      quads[parent_index].mass_y = (quads[parent_index].mass_y * old_mass + quads[child_index].mass_y * quads[child_index].mass) / new_mass
      quads[parent_index].mass = new_mass

      quads[parent_index].total += 1
    end
  end
end

task update_body_positions(bodies : region(body), quads : region(ispace(int1d), quad), root_index : uint)
where
  reads writes(bodies),
  reads(quads)
do
  var traverse_list : int1d[1024]
  for body in bodies do
    traverse_list[0] = root_index
    var traverse_index = 0

    while traverse_index >= 0 do
      var cur_index : int = traverse_list[traverse_index]
      traverse_index = traverse_index - 1
      if quads[cur_index].type == 2 then
        var dist = sqrt((body.mass_x - quads[cur_index].mass_x) * (body.mass_x - quads[cur_index].mass_x) + (body.mass_y - quads[cur_index].mass_y) * (body.mass_y - quads[cur_index].mass_y))

        if dist == 0 or quads[cur_index].size / dist >= theta then
          assert(traverse_index < 1020, "possible traverse list overflow")
          if quads[cur_index].sw ~= 1 then
            traverse_list[traverse_index + 1] = quads[cur_index].sw
            traverse_index += 1
          end

          if quads[cur_index].nw ~= 1 then
            traverse_list[traverse_index + 1] = quads[cur_index].nw
            traverse_index += 1
          end

          if quads[cur_index].se ~= 1 then
            traverse_list[traverse_index + 1] = quads[cur_index].se
            traverse_index += 1
          end

          if quads[cur_index].ne ~= 1 then
            traverse_list[traverse_index + 1] = quads[cur_index].ne
            traverse_index += 1
          end
        else
          var d_force = gee * body.mass * quads[cur_index].mass / (dist * dist)
          var xn = (quads[cur_index].mass_x - body.mass_x) / dist
          var yn = (quads[cur_index].mass_y - body.mass_y) / dist
          var d_force_x = d_force * xn
          var d_force_y = d_force * yn

          body.force_x += d_force_x
          body.force_y += d_force_y
        end
      else
        while cur_index ~= -1 do
          if quads[cur_index].index ~= body.index then
            var dist = sqrt((body.mass_x - quads[cur_index].mass_x) * (body.mass_x - quads[cur_index].mass_x) + (body.mass_y - quads[cur_index].mass_y) * (body.mass_y - quads[cur_index].mass_y))

            if dist > epsilon then
              var d_force = gee * body.mass * quads[cur_index].mass / (dist * dist)
              var xn = (quads[cur_index].mass_x - body.mass_x) / dist
              var yn = (quads[cur_index].mass_y - body.mass_y) / dist
              var d_force_x = d_force * xn
              var d_force_y = d_force * yn

              body.force_x += d_force_x
              body.force_y += d_force_y
            end
          end

          cur_index = quads[cur_index].next_in_leaf
        end
      end
    end
    body.mass_x = body.mass_x + body.speed_x * delta
    body.mass_y = body.mass_y + body.speed_y * delta
    body.speed_x = body.speed_x + body.force_x / body.mass * delta
    body.speed_y = body.speed_y + body.force_y / body.mass * delta
  end
end

task run_iteration(bodies : region(body), boundaries : region(boundary), conf : Config, sector_precision : uint)
  where
  reads writes(bodies),
  reads writes(boundaries)
do
  boundaries[0] = { min_x = bodies[0].mass_x, min_y = bodies[0].mass_y, max_x = bodies[0].mass_x, max_y = bodies[0].mass_y }
  
  var body_partition_index = ispace(ptr, conf.parallelism)

  var bodies_partition = partition(equal, bodies, body_partition_index)
  for i in body_partition_index do
    update_boundaries(bodies_partition[i], boundaries)
  end

  var min_x = boundaries[0].min_x
  var min_y = boundaries[0].min_y
  var size_x = boundaries[0].max_x - min_x
  var size_y = boundaries[0].max_y - min_y
  var size = max(size_x, size_y)

  __demand(__parallel)
  for i in body_partition_index do
    assign_sectors(bodies_partition[i], min_x, min_y, size, sector_precision)
  end
  
  var sector_index = ispace(int1d, sector_precision * sector_precision)
  var bodies_by_sector = partition(bodies.sector, sector_index)

  var partition_size = conf.fixed_partition_size
  if conf.fixed_partition_size == -1 then
    if conf.verbose then
      c.printf("Calculating required size of quad tree\n")
    end

    var max_size = region(ispace(ptr, 1), uint)
    max_size[0] = 0
    for i=0,conf.N do
      max_size[0] = max_size[0] + pow(4, i)
    end

    for i in sector_index do
      size_quad(bodies_by_sector[i], max_size, min_x, min_y, size, sector_precision, conf.leaf_size, i)
    end
      
    partition_size = max_size[0]
    if conf.verbose then
      c.printf("Quad tree size: %d\n", partition_size * (sector_precision * sector_precision + 1))
    end
  end

  var quads_split = ispace(int1d, sector_precision * sector_precision + 1)
  var quads_index = ispace(int1d, partition_size * (sector_precision * sector_precision + 1))
  var quads = region(quads_index, quad)
  fill(quads.{nw, sw, ne, se, next_in_leaf}, -1)

  var quads_partition = partition(equal, quads, quads_split)

  __demand(__parallel)
  for i in sector_index do
    build_quad(bodies_by_sector[i], quads_partition[i], min_x, min_y, size, sector_precision, conf.leaf_size, i, partition_size)
  end

  -- for i in quads_index do
    -- c.printf("%d Quad index: %d, type %d mass_x %f, mass_y %f, mass %f, center_x %f, center_y %f, size %f, total %d, sw %d, nw %d, se %d, ne %d\n", i, quads[i].index, quads[i].type, quads[i].mass_x, quads[i].mass_y, quads[i].mass, quads[i].center_x, quads[i].center_y, quads[i].size, quads[i].total, quads[i].sw, quads[i].nw, quads[i].se, quads[i].ne)
  -- end

  var to_merge : int[32][32]
  for i=0,sector_precision do
    for j=0,sector_precision do
      if quads[(i + j*sector_precision + 1) * partition_size].total > 0 then
        to_merge[i][j] = (i + j*sector_precision + 1) * partition_size
      else
        to_merge[i][j] = -1
      end
    end
  end
  
  var allocation_index = partition_size * sector_precision * sector_precision
  var level = sector_precision
  while level > 1 do
    var next_level = level / 2
    for i=0,next_level do
      for j=0,next_level do
        quads[allocation_index].size = size / next_level
        quads[allocation_index].center_x = min_x + size / next_level * (i + 0.5)
        quads[allocation_index].center_y = min_y + size / next_level * (j + 0.5)
        quads[allocation_index].type = 2

        quads[allocation_index].mass = 0
        quads[allocation_index].mass_x = 0
        quads[allocation_index].mass_y = 0
        quads[allocation_index].total = 0

        if to_merge[2*i][2*j] ~= -1 then
          quads[allocation_index].sw = to_merge[2*i][2*j]
          quads[allocation_index].mass += quads[to_merge[2*i][2*j]].mass
          quads[allocation_index].mass_x += quads[to_merge[2*i][2*j]].mass_x * quads[to_merge[2*i][2*j]].mass
          quads[allocation_index].mass_y += quads[to_merge[2*i][2*j]].mass_y * quads[to_merge[2*i][2*j]].mass
          quads[allocation_index].total += quads[to_merge[2*i][2*j]].total
        end

        if to_merge[2*i][2*j+1] ~= -1 then
          quads[allocation_index].nw = to_merge[2*i][2*j+1]
          quads[allocation_index].mass += quads[to_merge[2*i][2*j+1]].mass
          quads[allocation_index].mass_x += quads[to_merge[2*i][2*j+1]].mass_x * quads[to_merge[2*i][2*j+1]].mass
          quads[allocation_index].mass_y += quads[to_merge[2*i][2*j+1]].mass_y * quads[to_merge[2*i][2*j+1]].mass
          quads[allocation_index].total += quads[to_merge[2*i][2*j+1]].total
        end

        if to_merge[2*i+1][2*j] ~= -1 then
          quads[allocation_index].se = to_merge[2*i+1][2*j]
          quads[allocation_index].mass += quads[to_merge[2*i+1][2*j]].mass
          quads[allocation_index].mass_x += quads[to_merge[2*i+1][2*j]].mass_x * quads[to_merge[2*i+1][2*j]].mass
          quads[allocation_index].mass_y += quads[to_merge[2*i+1][2*j]].mass_y * quads[to_merge[2*i+1][2*j]].mass
          quads[allocation_index].total += quads[to_merge[2*i+1][2*j]].total
        end

        if to_merge[2*i+1][2*j+1] ~= -1 then
          quads[allocation_index].ne = to_merge[2*i+1][2*j+1]
          quads[allocation_index].mass += quads[to_merge[2*i+1][2*j+1]].mass
          quads[allocation_index].mass_x += quads[to_merge[2*i+1][2*j+1]].mass_x * quads[to_merge[2*i+1][2*j+1]].mass
          quads[allocation_index].mass_y += quads[to_merge[2*i+1][2*j+1]].mass_y * quads[to_merge[2*i+1][2*j+1]].mass
          quads[allocation_index].total += quads[to_merge[2*i+1][2*j+1]].total
        end

        if quads[allocation_index].total > 0 then
          quads[allocation_index].mass_x = quads[allocation_index].mass_x / quads[allocation_index].mass
          quads[allocation_index].mass_y = quads[allocation_index].mass_y / quads[allocation_index].mass
          to_merge[i][j] = allocation_index
        else
          to_merge[i][j] = -1
        end

        allocation_index = allocation_index + 1
      end
    end
    level = next_level
  end

  __demand(__parallel)
  for i in body_partition_index do
    update_body_positions(bodies_partition[i], quads, allocation_index)
  end
end

task main()
  var conf : Config
  conf.num_bodies = 16384
  conf.random_seed = 213
  conf.iterations = 10
  conf.output_dir_set = false
  conf.leaf_size = 32
  conf.N = 4
  conf.parallelism = 8
  conf.fixed_partition_size = -1
  conf.verbose = false

  conf = parse_input_args(conf)
  
  if conf.verbose then
    c.printf("settings: bodies=%d iterations=%d parallelism=%d N=%d leaf_size=%d seed=%d\n\n",
      conf.num_bodies, conf.iterations, conf.parallelism, conf.N, conf.leaf_size, conf.random_seed)
  end

  var bodies = region(ispace(ptr, conf.num_bodies), body)

  init_2_galaxies(bodies, conf)

  if conf.verbose then
    print_bodies_initial(bodies)
  end

  var sector_precision : uint = pow(2, conf.N)

  for i=0,conf.iterations do
      var boundaries = region(ispace(ptr, 1), boundary)
      fill(bodies.{force_x, force_y}, 0)
      run_iteration(bodies, boundaries, conf, sector_precision)

      if conf.verbose then
        var boundary = boundaries[0]
        c.printf("boundaries: min_x=%f min_y=%f max_x=%f max_y=%f\n\n", boundary.min_x, boundary.min_y, boundary.max_x, boundary.max_y)
        print_update(i, bodies, sector_precision)
      end

      if conf.output_dir_set then
        var fp = open(i, conf.output_dir)
        c.fprintf(fp, "<svg viewBox=\"0 0 850 850\" xmlns=\"http://www.w3.org/2000/svg\">")

        var boundary = boundaries[0]
        var size_x = boundary.max_x - boundary.min_x
        var size_y = boundary.max_y - boundary.min_y
        var size = max(size_x, size_y)
        var scale = 800.0 / size

        for body in bodies do
          var color = "black"
          if body.color == 1 then
            color = "blue"
          elseif body.color == 2 then
            color = "orange"
          end
          c.fprintf(fp, "<circle cx=\"%f\" cy=\"%f\" r=\"10\" fill=\"%s\" />", (body.mass_x - boundary.min_x) * scale + 25,  (body.mass_y - boundary.min_y) * scale + 25, color)
        end

        c.fprintf(fp, "</svg>")
        c.fclose(fp)
      end
  end
end
regentlib.start(main)
