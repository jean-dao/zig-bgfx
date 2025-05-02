$input v_position, v_normal

#include <bgfx_shader.sh>

uniform vec4 u_color;

void main()
{
    vec3 normal = normalize(v_normal);
    vec3 ligh_pos = vec3(20.0, 20.0, -20.0);
    vec3 light_dir = normalize(ligh_pos - v_position);
    vec3 light_color = vec3(1.0, 1.0, 1.0);

    vec3 ambient = 0.2 * light_color;
    vec3 diffuse = max(dot(normal, light_dir), 0.0) * light_color;

    vec3 color = u_color.xyz * 0.9;
    gl_FragColor.xyz = (ambient + diffuse) * color;
    gl_FragColor.w = 1.0;
}
