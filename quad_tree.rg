import "regent"

fspace quad(r : region(quad(wild))) {
  mass_x: double,
  mass_y: double,
  mass: double,
  center_x: double,
  center_y: double,
  size: double,
  total: uint,
  type: uint,
  index: uint,
  ne: ptr(quad(wild), r),
  nw: ptr(quad(wild), r),
  se: ptr(quad(wild), r),
  sw: ptr(quad(wild), r)
}

task add_node(quads : region(quad(wild)), parent: ptr(quad(wild), quads), child: ptr(quad(wild), quads), last_used: uint): uint
where
  reads(quads),
  writes(quads)
do
  var half_size = parent.size / 2
  var new_last_used = last_used
  if child.mass_x <= parent.center_x then
    if child.mass_y <= parent.center_y then
      if isnull(parent.sw) then
        parent.sw = child
      elseif dynamic_cast(ptr(quad(quads), quads), parent.sw).type == 1 then
        var new_fork = dynamic_cast(ptr(quad(quads), quads), last_used + 1)
        new_fork.type = 2
        new_fork.center_x = parent.center_x - half_size / 2
        new_fork.center_y = parent.center_y - half_size / 2
        new_fork.size = half_size
        new_last_used = add_node(quads, new_fork, dynamic_cast(ptr(quad(quads), quads), parent.sw), last_used + 1)
        new_last_used = add_node(quads, new_fork, child, new_last_used)
        parent.sw = new_fork
      else
        new_last_used = add_node(quads, parent.sw, child, last_used)
      end
    else
      if isnull(parent.nw) then
        parent.nw = child
      elseif dynamic_cast(ptr(quad(quads), quads), parent.nw).type == 1 then
        var new_fork = dynamic_cast(ptr(quad(quads), quads), last_used + 1)
        new_fork.type = 2
        new_fork.center_x = parent.center_x - half_size / 2
        new_fork.center_y = parent.center_y + half_size / 2
        new_fork.size = half_size
        new_last_used = add_node(quads, new_fork, dynamic_cast(ptr(quad(quads), quads), parent.nw), last_used + 1)
        new_last_used = add_node(quads, new_fork, child, new_last_used)
        parent.nw = new_fork
      else
        new_last_used = add_node(quads, parent.nw, child, last_used)
      end      
    end
  else
    if child.mass_y <= parent.center_y then
      if isnull(parent.se) then
        parent.se = child
      elseif dynamic_cast(ptr(quad(quads), quads), parent.se).type == 1 then
        var new_fork = dynamic_cast(ptr(quad(quads), quads), last_used + 1)
        new_fork.type = 2
        new_fork.center_x = parent.center_x + half_size / 2
        new_fork.center_y = parent.center_y - half_size / 2
        new_fork.size = half_size
        new_last_used = add_node(quads, new_fork, dynamic_cast(ptr(quad(quads), quads), parent.se), last_used + 1)
        new_last_used = add_node(quads, new_fork, child, new_last_used)
        parent.se = new_fork
      else
        new_last_used = add_node(quads, parent.se, child, last_used)
      end
    else
      if isnull(parent.ne) then
        parent.ne = child
      elseif dynamic_cast(ptr(quad(quads), quads), parent.ne).type == 1 then
        var new_fork = dynamic_cast(ptr(quad(quads), quads), last_used + 1)
        new_fork.type = 2
        new_fork.center_x = parent.center_x + half_size / 2
        new_fork.center_y = parent.center_x + half_size / 2
        new_fork.size = half_size
        new_last_used = add_node(quads, new_fork, dynamic_cast(ptr(quad(quads), quads), parent.ne), last_used + 1)
        new_last_used = add_node(quads, new_fork, child, new_last_used)
        parent.ne = new_fork
      else
        new_last_used = add_node(quads, parent.ne, child, last_used)
      end      
    end
  end

  parent.mass = 0
  parent.mass_x = 0
  parent.mass_y = 0
  
  if isnull(parent.sw) == false then
    var mass = dynamic_cast(ptr(quad(quads), quads), parent.sw).mass
    parent.mass += mass
    parent.mass_x += dynamic_cast(ptr(quad(quads), quads), parent.sw).mass_x * mass
    parent.mass_y += dynamic_cast(ptr(quad(quads), quads), parent.sw).mass_y * mass
  end 

  if isnull(parent.nw) == false then
    var mass = dynamic_cast(ptr(quad(quads), quads), parent.nw).mass
    parent.mass += mass
    parent.mass_x += dynamic_cast(ptr(quad(quads), quads), parent.nw).mass_x * mass
    parent.mass_y += dynamic_cast(ptr(quad(quads), quads), parent.nw).mass_y * mass
  end

  if isnull(parent.se) == false then
    var mass = dynamic_cast(ptr(quad(quads), quads), parent.se).mass
    parent.mass += mass
    parent.mass_x += dynamic_cast(ptr(quad(quads), quads), parent.se).mass_x * mass
    parent.mass_y += dynamic_cast(ptr(quad(quads), quads), parent.se).mass_y * mass
  end

  if isnull(parent.ne) == false then
    var mass = dynamic_cast(ptr(quad(quads), quads), parent.ne).mass
    parent.mass += mass
    parent.mass_x += dynamic_cast(ptr(quad(quads), quads), parent.ne).mass_x * mass
    parent.mass_y += dynamic_cast(ptr(quad(quads), quads), parent.ne).mass_y * mass
  end

  if parent.mass > 0 then
    parent.mass_x = parent.mass_x / parent.mass
    parent.mass_y = parent.mass_y / parent.mass
  end

  parent.total += 1

  return new_last_used
end