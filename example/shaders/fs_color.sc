$input v_position, v_normal

#include <bgfx_shader.sh>

uniform vec4 u_color;

void main()
{
    gl_FragColor = u_color;
}
