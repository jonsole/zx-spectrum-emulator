# Glossary Map

## Contexts

- [Cub](./examples/cub/GLOSSARY.md): a Piper Cub flight simulator for the 128K, built on fast3d

## Relationships

- **Cub → fast3d**: Cub draws its world with the fast3d engine in `examples/fast3d`, and the changes it needs there (near-plane clipping, a wrapping world) go into the engine for every program that uses it.
